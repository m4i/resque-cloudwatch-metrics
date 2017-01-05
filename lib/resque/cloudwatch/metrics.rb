# frozen_string_literal: true

require 'resque/cloudwatch/metrics/version'
require 'optparse'
require 'aws-sdk-core'
require 'resque'
require 'resque/cloudwatch/metrics/metric'

module Resque
  module CloudWatch
    class Metrics
      DEFAULT_CW_NAMESPACE = 'Resque'

      # http://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch_limits.html
      MAX_METRIC_DATA_PER_PUT = 20

      class << self
        def run(args)
          new(parse_arguments(args)).run
        end

        def parse_arguments(args)
          options = {}
          redis = {}
          skip = []
          extra = []

          opt = OptionParser.new
          opt.on('-h', '--host <host>')           { |v| redis[:host] = v }
          opt.on('-p', '--port <port>')           { |v| redis[:port] = v }
          opt.on('-s', '--socket <socket>')       { |v| redis[:path] = v }
          opt.on('-a', '--password <password>')   { |v| redis[:password] = v }
          opt.on('-n', '--db <db>')               { |v| redis[:db] = v }
          opt.on('--url <url>')                   { |v| options[:redis] = v }
          opt.on('--redis-namespace <namespace>') { |v| options[:redis_namespace] = v }
          opt.on('--cw-namespace <namespace>')    { |v| options[:cw_namespace] = v }
          opt.on('-i', '--interval <interval>')   { |v| options[:interval] = v.to_f }
          opt.on('--skip-pending')                { skip << :pending }
          opt.on('--skip-processed')              { skip << :processed }
          opt.on('--skip-failed')                 { skip << :failed }
          opt.on('--skip-queues')                 { skip << :queues }
          opt.on('--skip-workers')                { skip << :workers }
          opt.on('--skip-working')                { skip << :working }
          opt.on('--skip-pending-per-queue')      { skip << :pending_per_queue }
          opt.on('--not-working')                 { extra << :not_working }
          opt.on('--processing')                  { extra << :processing }
          opt.on('--dryrun')                      { options[:dryrun] = true }
          opt.parse(args)

          options[:redis] ||= redis unless redis.empty?

          metric = {}
          metric[:skip] = skip unless skip.empty?
          metric[:extra] = extra unless extra.empty?
          options[:metric] = metric unless metric.empty?

          options
        end
      end

      def initialize(redis: nil,
                     redis_namespace: nil,
                     cw_namespace: DEFAULT_CW_NAMESPACE,
                     interval: nil,
                     metric: {},
                     dryrun: false)
        Resque.redis = redis if redis
        @redis_namespace = redis_namespace
        @interval = interval
        @cw_namespace = cw_namespace
        @metric_options = metric
        @dryrun = dryrun
      end

      def run
        if @interval
          loop do
            thread = Thread.start { run_once }
            thread.abort_on_exception = true
            sleep @interval
          end
        else
          run_once
        end
      end

      private

      def run_once
        put_metric_data(
          redis_namespaces
            .map { |redis_namespace| Metric.create(redis_namespace, @metric_options) }
            .flat_map(&:to_cloudwatch_metric_data)
        )
      end

      def redis_namespaces
        if @redis_namespace
          if @redis_namespace.include?('*')
            suffix = ':queues'
            Resque.redis.redis.keys(@redis_namespace + suffix).map do |key|
              key[0 ... - suffix.length].to_sym
            end
          else
            [@redis_namespace.to_sym]
          end
        else
          [Resque.redis.namespace]
        end
      end

      def put_metric_data(metric_data)
        if @dryrun
          dump_metric_data(metric_data)
          return
        end

        metric_data.each_slice(MAX_METRIC_DATA_PER_PUT).map do |data|
          Thread.start(data, cloudwatch) do |data_, cloudwatch_|
            cloudwatch_.put_metric_data(
              namespace: @cw_namespace,
              metric_data: data_,
            )
          end
        end.each(&:join)
      end

      def dump_metric_data(metric_data)
        puts metric_data.to_json(
          indent:    ' ' * 2,
          space:     ' ',
          object_nl: "\n",
          array_nl:  "\n",
        )
      end

      def cloudwatch
        @_cloudwatch ||= Aws::CloudWatch::Client.new
      end
    end
  end
end
