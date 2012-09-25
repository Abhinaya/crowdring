module Crowdring
  class Supporter
    include DataMapper::Resource

    property :id,           Serial
    property :phone_number, String
    property :created_at,   DateTime

    belongs_to :campaign

    validates_with_method :phone_number, :valid_phone_number?

    after :save do |s|
      data = {  number: s.pretty_phone_number,
                supporter_count: s.campaign.supporters.count,
                new_supporter_count: s.campaign.new_supporters.count }
      Pusher[s.campaign.phone_number[1..-1]].trigger('new', data) 
    end

    def pretty_phone_number
      number = Phoner::Phone.parse phone_number
      number.format "+%c (%a) %n" + " [" + Phoner::Country.find_by_country_code(number.country_code).char_3_code + "]"
    end

    def support_date
      created_at.strftime('%F')
    end


    private

    def valid_phone_number?
      if Phoner::Phone.valid? @phone_number
        true
      else
        [false, 'Phone number does not appear to be valid']
      end
    end
  end
end