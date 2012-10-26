module Crowdring
  def self.statsd
    @statsd ||= Statsd.new(ENV['STATSD_HOST'] || "http://localhost").tap do |s|
      s.namespace = "crowdring"
    end
  end

  class Server < Sinatra::Base
    register Sinatra::SinatraAuthentication
    enable :sessions
    use Rack::Flash
    set :logging, true
    set :root, File.dirname(__FILE__) + '/..'
    set :sinatra_authentication_view_path, settings.views + "/auth/"
    set :protection, except: :frame_options

    include LazyHighCharts::LayoutHelper

    def self.service_handler
      CompositeService.instance
    end

    configure :development do
      register Sinatra::Reloader
      service_handler.add('logger', LoggingService.new(['+18001111111', '+18002222222', '+27114891907'], output: true), default: true)
    end

    configure :production do
      service_handler.add('twilio', TwilioService.new(ENV["TWILIO_ACCOUNT_SID"], ENV["TWILIO_AUTH_TOKEN"]), default: true)
      service_handler.add('kookoo', KooKooService.new(ENV["KOOKOO_API_KEY"], ENV["KOOKOO_NUMBER"]))
      service_handler.add('tropo.json', TropoService.new(ENV["TROPO_MSG_TOKEN"], ENV["TROPO_APP_ID"], 
        ENV["TROPO_USERNAME"], ENV["TROPO_PASSWORD"]))
      service_handler.add('voxeo', VoxeoService.new(ENV["VOXEO_APP_ID"], ENV["VOXEO_USERNAME"], ENV["VOXEO_PASSWORD"]))
      service_handler.add('nexmo', NexmoService.new(ENV["NEXMO_KEY"], ENV["NEXMO_SECRET"]))
    end

    configure do
      $stdout.sync = true

      Pusher.app_id = ENV["PUSHER_APP_ID"]
      Pusher.key = ENV["PUSHER_KEY"]
      Pusher.secret = ENV["PUSHER_SECRET"]
      
      database_url = ENV["DATABASE_URL"] || "postgres://localhost/crowdring_#{settings.environment}"
      DataMapper.setup(:default, database_url)
      DataMapper.finalize

      redis_url = ENV["REDISTOGO_URL"] || 'redis://localhost:6379'
      uri = URI.parse(redis_url)
      Resque.redis = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password, :thread_safe => true)
    end


    helpers do
      def to_attributes(options)
        options.map {|k, v| v.nil? ? '' : " #{k}='#{v}'"}.join
      end
      
      def content_tag(type, content, options={})
        "<#{type}#{to_attributes(options)}>#{content}</#{type}>"
      end
    end

    before /^((?!((voice|sms)response)|login|resetpassword|progress-embed).)*$/ do
      login_required unless settings.environment == :test
    end

    before /(voice|sms)response/ do
      Crowdring.statsd.increment "#{$1}_received.count"
    end

    def sms_response
      []
    end

    def voice_response
      [{cmd: :reject}]
    end

    def respond(cur_service, request, response)
      if AssignedVoiceNumber.from(request.to)
        ringer = Ringer.from(request.from)
        AssignedVoiceNumber.from(request.to).ring(ringer)
      end

      cur_service.build_response(request.to, response)
    end

    def process_request(service_name, request, response)
      cur_service = Server.service_handler.get(service_name)
      cur_request = cur_service.transform_request(request)

      if cur_request.callback?
        cur_service.process_callback(cur_request)
      else
        respond(cur_service, cur_request, response)
      end
    end

    post '/smsresponse/:service' do
      process_request(params[:service], request, sms_response)
    end

    get '/smsresponse/:service' do
      process_request(params[:service], request, sms_response)
    end

    post '/voiceresponse/:service' do
      process_request(params[:service], request, voice_response)
    end

    get '/voiceresponse/:service' do 
      process_request(params[:service], request, voice_response)
    end

    get '/' do  
      @campaigns = Campaign.all

      haml :index
    end

    get '/campaigns' do
      @campaigns = Campaign.all

      haml :campaigns
    end

    get '/campaign/new' do
      used_voice_numbers = AssignedVoiceNumber.all.map(&:phone_number)
      @voice_numbers = Server.service_handler.voice_numbers - used_voice_numbers

      used_sms_numbers = AssignedSMSNumber.all.map(&:phone_number)
      @sms_numbers = Server.service_handler.sms_numbers - used_sms_numbers

      haml :campaign_new
    end

    post '/campaign/create' do
      campaign = Campaign.new(params[:campaign])
      if campaign.save
        flash[:notice] = "Campaign created"
        redirect to("/campaigns##{campaign.id}")
      else
        flash[:errors] = campaign.all_errors.map(&:full_messages).flatten.join('|')
        redirect to('/campaign/new')
      end
    end
    
    get '/campaign/:id/assign_voice_number' do 
      @campaign = Campaign.get(params[:id])
      @voice_numbers = Server.service_handler.voice_numbers - AssignedVoiceNumber.all.map(&:phone_number)      
      
      haml :campaign_assign_voice_number        
    end

    post '/campaign/:id/assign_voice_number' do 
      campaign = Campaign.get(params[:id])
      campaign.voice_numbers.new(params[:voice_number])
      if campaign.save
        flash[:notice] = "Voice number assigned"
       redirect to("/campaigns##{campaign.id}")
      else
        flash[:errors] = campaign.all_errors.map(&:full_messages).flatten.join('|')
        redirect to("/campaign/#{campaign.id}/assign_voice_number")
      end
    end

    post '/campaign/:id/destroy' do
      campaign = Campaign.get(params[:id])
      if campaign.destroy
        flash[:notice] = "Campaign destroyed"
      else
        flash[:errors] = "Failed to destroy campaign|" + campaign.errors.full_messages.join('|')
      end

      redirect to('/')
    end

    get '/campaign/:id' do
      @campaign = Campaign.get(params[:id])
      if @campaign
        @ringers =  @campaign.rings.all(order: [:created_at.desc], limit: 10).map(&:ringer)
        @ring_count = @campaign.rings.count
        @ringer_count = @campaign.ringers.count
        @countries = @campaign.ringers.map(&:country).uniq
        @all_fields = CsvField.all_fields
        @basic_chart = HighChartsBuilder.basic_stats(@campaign)

        haml :campaign, layout: !request.xhr?
      else
        flash[:errors] = "No campaign with id #{params[:id]}"
        404
      end
    end

    get '/campaign/:id/progress-embed' do
      @campaign = Campaign.get(params[:id])
      @color = params[:color]
      haml :campaign_progress_embedded, layout: false
    end

    get '/campaign/:id/csv' do
      attachment("#{params[:id]}.csv")
      rings = Filter.create(params[:filter]).filter(Campaign.get(params[:id]).unique_rings)
      fields = params.key?('fields') ? params[:fields].keys.map {|id| CsvField.from_id id } : CsvField.default_fields
      CSV.generate do |csv|
        csv << fields.map {|f| f.display_name }
        rings.each {|ring| csv << fields.map {|f| ring.send(f.id) } }
      end
    end


    post '/campaign/:id/broadcast' do
      campaign = Campaign.get(params[:id])
      from = params[:from] || campaign.sms_number.phone_number
      message = params[:message]
      rings = Filter.create(params[:filter]).filter(Campaign.get(params[:id]).rings)
      to = rings.map(&:ringer).map(&:phone_number)

      Server.service_handler.broadcast(from, message, to)
      campaign.most_recent_broadcast = DateTime.now
      campaign.save

      flash[:notice] = "Message broadcast"
      redirect to("/campaigns##{campaign.id}")
    end

    get '/tags/new' do
      haml :tag_new
    end

    post '/tags/create' do
      tag = Tag.from_str(params[:type] + ':' + params[:value])
      if tag.saved?
        flash[:notice] = "#{tag} tag created"
        redirect to('/')
      else
        flash[:errors] = tag.errors.full_messages.join('|')
        redirect to('/tags/new')
      end
    end

    get '/tags/tags.json' do
      content_type :json

      Tag.all.map {|tag| {category: tag.type, visible_label: tag.value, label: tag.to_s} }.to_json
    end

    run! if app_file == $0
  end
end