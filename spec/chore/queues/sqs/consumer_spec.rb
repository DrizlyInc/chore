require 'spec_helper'

describe Chore::Queues::SQS::Consumer do
  let(:queue_name) { "test" }
  let(:queues) { double("queues") }
  let(:queue) { double("test_queue") }
  let(:options) { {} }
  let(:consumer) { Chore::Queues::SQS::Consumer.new(queue_name) }
  let(:message) { TestMessage.new("handle","message body") }

  before do
    AWS::SQS.any_instance.stub(:queues).and_return { queues }
    queues.stub(:named) { queue }
    queue.stub(:receive_message) { message }
    queue.stub(:visibility_timeout) { 10 }
  end

  describe "consuming messages" do
    let!(:consumer_run_for_one_message) { consumer.stub(:running?).and_return(true, false) }
    let!(:messages_be_unique) { Chore::DuplicateDetector.any_instance.stub(:found_duplicate?).and_return(false) }
    let!(:queue_contain_messages) { queue.stub(:receive_messages).and_return(message) }

    it "should receive a message from the queue" do
      queue.should_receive(:receive_messages)
      consumer.consume
    end

    it "should check the uniqueness of the message" do
      Chore::DuplicateDetector.any_instance.should_receive(:found_duplicate?).with(message).and_return(false)
      consumer.consume
    end

    it "should yield the message to the handler block" do
      expect { |b| consumer.consume(&b).to yield_control(message) }
    end

    it 'should not yield for a dupe message' do
      Chore::DuplicateDetector.any_instance.should_receive(:found_duplicate?).with(message).and_return(true)
      expect {|b| consumer.consume(&b) }.not_to yield_control
    end
  end

  describe '#reset_connection!' do
    it 'should reset the connection after a call to reset_connection!' do
      sqs = consumer.send(:sqs)
      Chore::Queues::SQS::Consumer.reset_connection!
      sqs.should_not be consumer.send(:sqs)
    end

    it 'should not reset the connection between calls' do
      sqs = consumer.send(:sqs)
      sqs.should be consumer.send(:sqs)
    end
  end
end