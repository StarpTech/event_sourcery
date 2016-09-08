module EventSourcery
  module EventProcessing
    module Projector
      def self.included(base)
        base.include(EventStreamProcessor)
        base.prepend(TableOwner)
        base.include(InstanceMethods)
        base.class_eval do
          alias project process

          class << self
            alias projects_events processes_events
          end
        end
      end

      module InstanceMethods
        def initialize(tracker:, db_connection:)
          @tracker = tracker
          @db_connection = db_connection
        end

        private

        def process_method_name
          'project'
        end

        def process_events(events)
          events.each do |event|
            db_connection.transaction do
              process(event)
              tracker.processed_event(processor_name, event.id)
            end
          end
        end
      end
    end
  end
end