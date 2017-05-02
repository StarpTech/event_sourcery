RSpec.describe EventSourcery::AggregateRoot do
  def new_aggregate(id,
                    on_unknown_event: EventSourcery.config.on_unknown_event,
                    &block)
    Class.new do
      include EventSourcery::AggregateRoot

      def initialize(id,
                     events,
                     event_sink,
                     on_unknown_event: -> {})
        @item_added_events = []
        super
      end

      apply ItemAdded do |event|
        @item_added_events << event
      end
      attr_reader :item_added_events

      class_eval(&block) if block_given?
    end.new(id,
            events,
            event_sink,
            on_unknown_event: on_unknown_event)
  end

  let(:aggregate_uuid) { SecureRandom.uuid }
  subject(:aggregate) { new_aggregate(aggregate_uuid) }
  let(:event_store) { EventSourcery::Postgres::EventStoreWithOptimisticConcurrency.new(pg_connection, event_builder: EventSourcery.config.event_builder) }
  let(:event_sink) { EventSourcery::EventStore::EventSink.new(event_store) }

  describe '#initialize', 'with events' do
    context 'when the event type has a state change method' do
      let(:events) { [new_event(type: :item_added)] }

      it 'calls it' do
        expect(aggregate.item_added_events).to eq events
      end
    end

    context "when the aggregate doesn't have a state change method for the loaded event" do
      let(:events) { [new_event(type: :item_removed)] }

      context 'using the default on_unknown_event' do
        it 'raises an error' do
          expect { aggregate }
            .to raise_error(EventSourcery::AggregateRoot::UnknownEventError)
        end
      end

      context 'using a custom on_unknown_event' do
        let(:custom_on_unknown_event) { spy }
        let(:aggregate) { new_aggregate(aggregate_uuid, on_unknown_event: custom_on_unknown_event) }

        it 'yields the event and aggregate to the on_unknown_event block' do
          aggregate
          expect(custom_on_unknown_event)
            .to have_received(:call)
            .with(events.first, kind_of(EventSourcery::AggregateRoot))
        end
      end
    end
  end

  describe '#apply_event' do
    let(:events) { [] }

    before do
      # add a dummy event so that event.id != event.version
      event_store.sink(new_event(id: 1, type: :dummy, version: 1, aggregate_id: SecureRandom.uuid))
    end

    subject(:aggregate) {
      new_aggregate(aggregate_uuid) do
        def add_item(item)
          apply_event(ItemAdded.new(body: { id: item.id }))
        end
      end
    }

    it 'updates state' do
      aggregate.add_item(OpenStruct.new(id: 1234))
      event = aggregate.item_added_events.first
      expect(event.type).to eq 'item_added'
      expect(event.body).to eq("id" => 1234)
    end

    it 'saves the event with an initial version' do
      aggregate.add_item(OpenStruct.new(id: 1234))
      emitted_event = event_store.get_next_from(0).last
      expect(emitted_event.id).to eq 2
      expect(emitted_event.type).to eq 'item_added'
      expect(emitted_event.body).to eq('id' => 1234)
      expect(emitted_event.aggregate_id).to eq aggregate_uuid
      expect(emitted_event.version).to eq 1
    end

    context 'processing multiple commands' do
      it 'gets assigned the next version (no concurrent command processing occurred)' do
        aggregate.add_item(OpenStruct.new(id: 1234))
        aggregate.add_item(OpenStruct.new(id: 1234))
        aggregate.add_item(OpenStruct.new(id: 1234))
        emitted_versions = event_store.get_events_for_aggregate_id(aggregate_uuid).map(&:version)
        expect(emitted_versions).to eq([1, 2, 3])
      end
    end

    context 'when a concurrency error occurs' do
      let(:events) { event_store.get_events_for_aggregate_id(aggregate_uuid) }

      it 'is raised' do
        aggregate
        # change version
        event_store.sink(EventSourcery::Event.new(type: :item_added, aggregate_id: aggregate_uuid))
        expect {
          aggregate.add_item(OpenStruct.new(id: 1234))
        }.to raise_error(EventSourcery::ConcurrencyError)
      end
    end

    context 'given an event hash' do
      subject(:aggregate) do
        new_aggregate(aggregate_uuid) do
          def add_item(item)
            apply_event(ItemAdded.new(body: { id: item.id }))
          end
        end
      end

      it 'updates state' do
        aggregate.add_item(OpenStruct.new(id: 1234))

        event = aggregate.item_added_events.first
        expect(event.type).to eq 'item_added'
        expect(event.body).to eq('id' => 1234)
      end

      it 'saves the event with an initial version' do
        aggregate.add_item(OpenStruct.new(id: 1234))

        emitted_event = event_store.get_next_from(0).last
        expect(emitted_event.id).to eq 2
        expect(emitted_event.type).to eq 'item_added'
        expect(emitted_event.body).to eq('id' => 1234)
        expect(emitted_event.aggregate_id).to eq aggregate_uuid
        expect(emitted_event.version).to eq 1
      end
    end
  end

  it 'is impossible to insert a duplicate version directly' do
    pg_connection[:events].insert(aggregate_id: aggregate_uuid,
                                  type: 'blah',
                                  body: Sequel.pg_json({}),
                                  version: 1)
    expect {
      pg_connection[:events].insert(aggregate_id: aggregate_uuid,
                                    type: 'blah',
                                    body: Sequel.pg_json({}),
                                    version: 1)
    }.to raise_error(Sequel::UniqueConstraintViolation)
  end

  context 'loading state' do
    let(:item_added_event) { ItemAdded.new(id: 1) }
    let(:item_removed_event) { ItemRemoved.new(id: 2) }

    context 'with custom event classes' do
      let(:events) { [item_added_event] }

      it 'sends events to the event handlers' do
        aggregate = new_aggregate(aggregate_uuid) do |event|
          apply(ItemAdded) do |event|
            @item_added_event_via_dsl = event
          end

          apply(ItemRemoved) do |event|
            @item_removed_event_via_dsl = event
          end

          attr_reader :item_added_event_via_dsl,
                      :item_removed_event_via_dsl
        end
        expect(aggregate.item_added_event_via_dsl).to eq item_added_event
        expect(aggregate.item_removed_event_via_dsl).to be_nil
      end

      context 'with multiple events' do
        let(:events) { [item_added_event, item_removed_event] }

        it 'handles multiple events in handlers' do
          aggregate = new_aggregate(aggregate_uuid) do
            apply ItemAdded do |event|
              @added_event = event
            end

            apply ItemAdded, ItemRemoved do |event|
              @added_and_removed_events ||= []
              @added_and_removed_events << event
            end

            attr_reader :added_and_removed_events, :added_event
          end

          expect(aggregate.added_event).to eq item_added_event
          expect(aggregate.added_and_removed_events).to eq [item_added_event, item_removed_event]
        end
      end
    end
  end
end