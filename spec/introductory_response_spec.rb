require File.dirname(__FILE__) + '/spec_helper'

describe Crowdring::IntroductoryResponse do

  before(:each) do
    DataMapper::auto_migrate!
 
    @number = '+11111111111'
    @number2 = '+22222222222'
    @fooresponse = double('fooresponse', callback?: false, from: @number2, to: @number)
    @fooservice = double('fooservice', build_response: 'fooResponse',
        supports_outgoing?: true,
        transform_request: @fooresponse,
        numbers: [@number],
        send_sms: nil)
    @ringer = double('ringer', phone_number: @number2)
    Crowdring::CompositeService.instance.reset
    Crowdring::CompositeService.instance.add('foo', @fooservice) 
  end

  it 'should send the default message if no filters are provided' do
    @fooservice.should_receive(:send_sms).once.with(from: @number, to: @number2, msg: 'default')

    intro_response = Crowdring::IntroductoryResponse.create_with_default('default')
    intro_response.send_message(from: @number, to: @ringer)
  end

  it 'should send the first matched message to a ringer' do
    pittsburgh = Crowdring::Tag.from_str('area code:412')
    chicago = Crowdring::Tag.from_str('area code:312')
    fm = Crowdring::TagFilter.create
    fm.tags << pittsburgh
    fm2 = Crowdring::TagFilter.create
    fm2.tags << chicago

    intro_response = Crowdring::IntroductoryResponse.create_with_default('default')
    intro_response.add_message(fm2, 'chicago')
    intro_response.add_message(fm, 'pittsburgh')

    @ringer.stub(:tags) { [pittsburgh] }
    @fooservice.should_receive(:send_sms).once.with(from: @number, to: @number2, msg: 'pittsburgh')

    intro_response.send_message(from: @number, to: @ringer)
  end

  it 'should send the default message if no filters match' do
    pittsburgh = Crowdring::Tag.from_str('area code:412')
    chicago = Crowdring::Tag.from_str('area code:312')
    fm2 = Crowdring::TagFilter.create
    fm2.tags << chicago

    intro_response = Crowdring::IntroductoryResponse.create_with_default('default')
    intro_response.add_message(fm2, 'chicago')

    @ringer.stub(:tags) { [pittsburgh] }
    @fooservice.should_receive(:send_sms).once.with(from: @number, to: @number2, msg: 'default')

    intro_response.send_message(from: @number, to: @ringer)
  end

end