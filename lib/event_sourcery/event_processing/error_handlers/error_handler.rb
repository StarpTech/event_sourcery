module EventSourcery
  module EventProcessing
    module ErrorHandlers
      module ErrorHandler
        # The default with_error_handling method. Will always raise NotImplementedError
        #
        # @raise [NotImplementedError]
        def with_error_handling
          raise NotImplementedError, 'Please implement #with_error_handling method'
        end

        private

        def report_error(error)
          error = error.cause if error.instance_of?(EventSourcery::EventProcessingError)
          EventSourcery.logger.error("Processor #{@processor_name} died with #{error}.\n#{error.backtrace.join("\n")}")

          EventSourcery.config.on_event_processor_error.call(error, @processor_name)
        end
      end
    end
  end
end
