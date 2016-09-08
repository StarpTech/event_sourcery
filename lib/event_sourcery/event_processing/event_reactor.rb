module EventSourcery
  module EventProcessing
    module EventReactor
      UndeclaredEventEmissionError = Class.new(StandardError)

      def self.included(base)
        base.include(EventStreamProcessor)
        base.extend(ClassMethods)
        base.prepend(TableOwner)
        base.include(InstanceMethods)
      end

      module ClassMethods
        def emits_events(*event_types)
          @emits_event_types = event_types.map(&:to_s)
        end

        def emit_events
          @emits_event_types ||= []
        end

        def emits_events?
          !emit_events.empty?
        end

        def emits_event?(event_type)
          emit_events.include?(event_type.to_s)
        end
      end

      module InstanceMethods
        def initialize(tracker:, db_connection: nil, event_source: nil, event_sink: nil)
          @tracker = tracker
          @event_source = event_source
          @event_sink = event_sink
          @db_connection = db_connection
          if self.class.emits_events?
            if event_sink.nil? || event_source.nil?
              raise ArgumentError, 'An event sink and source is required for processors that emit events'
            end
          end
        end
      end

      DRIVEN_BY_EVENT_PAYLOAD_KEY = :_driven_by_event_id

      private

      attr_reader :event_sink, :event_source

      def emit_event(event, &block)
        raise UndeclaredEventEmissionError unless self.class.emits_event?(event.type)
        body = event.body.merge(DRIVEN_BY_EVENT_PAYLOAD_KEY => _event.id)
        Event.new(aggregate_id: event.aggregate_id,
                  type: event.type,
                  body: body)
        invoke_action_and_emit_event(event, block)
      end

      def invoke_action_and_emit_event(event, action)
        action.call(event.body) if action
        # TODO: emit_event should probably take an event object rather than these params
        event_sink.sink(event)
      end
    end
  end
end