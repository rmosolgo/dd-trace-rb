require 'support/faux_writer'
require 'support/network_helpers'

require 'datadog/tracing/tracer'
require 'datadog/tracing/span'
require 'datadog/tracing/sync_writer'

module Contrib
  include NetworkHelpers
  # Contrib-specific tracer helpers.
  # For contrib, we only allow one tracer to be active:
  # the global tracer in +Datadog::Tracing+.
  module TracerHelpers
    # Returns the current tracer instance
    def tracer
      Datadog::Tracing.send(:tracer)
    end

    # Returns spans and caches it (similar to +let(:spans)+).
    def traces
      @traces ||= fetch_traces
    end

    # Returns spans and caches it (similar to +let(:spans)+).
    def spans
      @spans ||= fetch_spans
    end

    # Retrieves all traces in the current tracer instance.
    # This method does not cache its results.
    def fetch_traces(tracer = self.tracer)
      tracer.instance_variable_get(:@traces) || []
    end

    # Retrieves and sorts all spans in the current tracer instance.
    # This method does not cache its results.
    def fetch_spans(tracer = self.tracer)
      traces = fetch_traces(tracer)
      traces.collect(&:spans).flatten.sort! do |a, b|
        if a.name == b.name
          if a.resource == b.resource
            if a.start_time == b.start_time
              a.end_time <=> b.end_time
            else
              a.start_time <=> b.start_time
            end
          else
            a.resource <=> b.resource
          end
        else
          a.name <=> b.name
        end
      end
    end

    # Remove all traces from the current tracer instance and
    # busts cache of +#spans+ and +#span+.
    def clear_traces!
      tracer.instance_variable_set(:@traces, [])

      @traces = nil
      @trace = nil
      @spans = nil
      @span = nil
    end

    RSpec.configure do |config|
      # Capture spans from the global tracer
      config.before do
        # DEV `*_any_instance_of` has concurrency issues when running with parallelism (e.g. JRuby).
        # DEV Single object `allow` and `expect` work as intended with parallelism.
        allow(Datadog::Tracing::Tracer).to receive(:new).and_wrap_original do |method, **args, &block|
          instance = method.call(**args, &block)

          # The mutex must be eagerly initialized to prevent race conditions on lazy initialization
          write_lock = Mutex.new
          allow(instance).to receive(:write) do |trace|
            instance.instance_exec do
              write_lock.synchronize do
                @traces ||= []
                @traces << trace
              end
            end
          end
          instance
        end
        # # override service name resolution method in order to save service name for later testing
        # original_service_method = Datadog::Tracing::Contrib::SpanAttributeSchema.method(:fetch_service_name)
        # allow(Datadog::Tracing::Contrib::SpanAttributeSchema).to receive(:fetch_service_name) do |env, default|
        #   service_name = original_service_method.call(env, default)
        #   ENV['DD_CONFIGURED_INTEGRATION_SERVICE'] = service_name
        #   service_name
        # end
        # # override integration service configuration method in order to save override service name for later testing
        # original_configuration_for_method = Datadog.method(:configuration_for)
        # allow(Datadog).to receive(:configuration_for) do |target, option|
        #   config = original_configuration_for_method.call(target, option)
        #   if option == :service_name
        #     ENV['DD_CONFIGURED_INTEGRATION_INSTANCE_SERVICE'] = config
        #   elsif option.nil? && config.key?(:service_name)
        #     ENV['DD_CONFIGURED_INTEGRATION_INSTANCE_SERVICE'] = config[:service_name]
        #   end
        #   config
        # end
        # original_configure_onto_method = Datadog.method(:configure_onto)
        # allow(Datadog).to receive(:configure_onto) do |target, options = {}|
        #   if options.key? :service_name
        #     ENV['DD_CONFIGURED_INTEGRATION_INSTANCE_SERVICE'] = options[:service_name]
        #   end
        #   original_configure_onto_method.call(target, **options)
        # end
        # service_name_method = Datadog::Tracing::Contrib::HttpAnnotationHelper.instance_method(:service_name)
        # allow_any_instance_of(Datadog::Tracing::Contrib::HttpAnnotationHelper).to receive(:service_name) do |instance, hostname, configuration_options, pin|
        #   service_name = service_name_method.bind(instance).call(hostname, configuration_options, pin)
        #   ENV['DD_CONFIGURED_INTEGRATION_INSTANCE_SERVICE'] = service_name
        #   service_name
        # end
        # api_configuration_method = Datadog::Tracing::Contrib::Extensions::Configuration::Settings.instance_method(:[])
        # allow_any_instance_of(Datadog::Tracing::Contrib::Extensions::Configuration::Settings).to receive(:[]) do |instance, integration_name, key = :default|
        #   configuration = api_configuration_method.bind(instance).call(integration_name, key)
        #   if configuration.to_h.key?(:service_name)
        #     ENV['DD_CONFIGURED_INTEGRATION_INSTANCE_SERVICE'] = configuration[:service_name]
        #   end
        #   configuration
        # end
      end

      # Execute shutdown! after the test has finished
      # teardown and mock verifications.
      #
      # Changing this to `config.after(:each)` would
      # put shutdown! inside the test scope, interfering
      # with mock assertions.
      config.around do |example|
        example.run.tap do
          Datadog::Tracing.shutdown!
        end
      end

      config.after do
        traces = fetch_traces(tracer)
        unless traces.empty?
          if tracer.respond_to?(:writer) && tracer.writer.transport.client.api.adapter.respond_to?(:hostname) && # rubocop:disable Style/SoleNestedConditional
              tracer.writer.transport.client.api.adapter.hostname == 'testagent' && test_agent_running?
            traces.each do |trace|
              transport = tracer.writer.transport
              # write traces after the test to the agent in order to not mess up assertions
              headers = transport.client.api.headers
              headers.delete('X-Datadog-Trace-Env-Variables')
              parse_tracer_config_and_add_to_headers(headers, trace)
              sync_writer = Datadog::Tracing::SyncWriter.new(transport: transport)
              sync_writer.write(trace)
            end
          end
        end
      end
    end

    # Useful for integration testing.
    def use_real_tracer!
      @use_real_tracer = true
      allow(Datadog::Tracing::Tracer).to receive(:new).and_call_original
    end
  end
end
