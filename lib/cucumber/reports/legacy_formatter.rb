require 'forwardable'
require 'delegate'
require 'cucumber/errors'
require 'cucumber/multiline_argument'

module Cucumber
  module Reports

    class FormatterWrapper < BasicObject
      attr_reader :formatters
      private :formatters

      def initialize(formatters)
        @formatters = formatters
      end

      def method_missing(message, *args)
        formatters.each do |formatter|
          formatter.send(message, *args) if formatter.respond_to?(message)
        end
      end

      def respond_to_missing?(name, include_private = false)
        formatters.any? { |formatter| formatter.respond_to?(name, include_private) }
      end

    end

    LegacyFormatter = Struct.new(:runtime, :formatter) do

      def initialize(runtime, formatters)
        super runtime, FormatterWrapper.new(formatters)
      end

      extend Forwardable

      def_delegators :formatter,
        :ask

      def_delegators :printer,
        :before_test_case,
        :before_test_step,
        :after_test_step

      def after_test_case(test_case, result)
        record_test_case_result(test_case, result)
        printer.after_test_case(test_case, result)
      end

      def puts(*messages)
        printer.puts(messages)
      end

      def embed(src, mime_type, label)
        printer.embed(src, mime_type, label)
      end

      def done
        printer.after
      end

      private

      def printer
        @printer ||= FeaturesPrinter.new(formatter, runtime).before
      end

      def record_test_case_result(test_case, result)
        scenario = LegacyResultBuilder.new(result).scenario(test_case.name, test_case.location)
        runtime.record_result(scenario)
      end

      require 'cucumber/core/test/timer'
      FeaturesPrinter = Struct.new(:formatter, :runtime) do
        extend Forwardable

        def before
          timer.start
          formatter.before_features(nil)
          self
        end

        def before_test_case(test_case)
          test_case.describe_source_to(self)
          @child.before_test_case(test_case)
        end

        def before_test_step(*args)
          @child.before_test_step(*args)
        end

        def after_test_step(test_step, result)
          @child.after_test_step(test_step, result)
        end

        def after_test_case(*args)
          @child.after_test_case(*args)
        end

        def feature(node, *)
          if node != @current_feature
            @child.after if @child
            @child = FeaturePrinter.new(formatter, runtime, node).before
            @current_feature = node
          end
        end

        def scenario(node, *)
        end

        def scenario_outline(node, *)
        end

        def examples_table(node, *)
        end

        def examples_table_row(node, *)
        end

        def after
          @child.after if @child
          formatter.after_features Legacy::Ast::Features.new(timer.sec)
          self
        end

        def puts(messages)
          @child.puts(messages)
        end

        def embed(src, mime_type, label)
          @child.embed(src, mime_type, label)
        end

        private

        def timer
          @timer ||= Cucumber::Core::Test::Timer.new
        end
      end

      module TestStepSource
        def self.for(test_step, result)
          collector = Collector.new
          test_step.describe_source_to collector, result
          collector.result.freeze
        end

        class Collector
          attr_reader :result

          def initialize
            @result = StepSource.new
          end

          def method_missing(name, node, step_result, *args)
            result.send "#{name}=", node
            result.send "#{name}_result=", LegacyResultBuilder.new(step_result)
          end
        end

        require 'ostruct'
        class StepSource < OpenStruct
          def build_step_invocation(indent, runtime, messages, embeddings)
            step_result.step_invocation(
              step_match(runtime),
              step,
              indent,
              background,
              runtime.configuration,
              messages,
              embeddings
            )
          end

          private

          def step_match(runtime)
            runtime.step_match(step.name)
          rescue Cucumber::Undefined
            NoStepMatch.new(step, step.name)
          end
        end

      end

      Embedding = Struct.new(:src, :mime_type, :label) do

        def send_to_formatter(formatter)
          formatter.embed(src, mime_type, label)
        end
      end

      FeaturePrinter = Struct.new(:formatter, :runtime, :node) do

        def before
          formatter.before_feature(node)
          Legacy::Ast::Comments.new(node.comments).accept(formatter)
          Legacy::Ast::Tags.new(node.tags).accept(formatter)
          formatter.feature_name node.keyword, indented(node.legacy_conflated_name_and_description)
          @delayed_messages = []
          @delayed_embeddings = []
          self
        end

        attr_reader :current_test_step_source

        def before_test_case(test_case)
          @before_hook_results = Legacy::Ast::NodeCollection.new
        end

        def before_test_step(test_step)
        end

        def after_test_step(test_step, result)
          @current_test_step_source = TestStepSource.for(test_step, result)
          # TODO: stop calling self, and describe source to another object
          test_step.describe_source_to(self, result)
          print_step
        end

        def after_test_case(*args)
          if current_test_step_source.step_result.nil?
            switch_step_container
          end

          # messages and embedding should already have been handled, but just in case...
          @delayed_messages.each { |message| formatter.puts(message) }
          @delayed_embeddings.each { |embedding| embedding.send_to_formatter(formatter) }
          @delayed_messages = []
          @delayed_embeddings = []

          @child.after_test_case
          @previous_test_case_background = @current_test_case_background
          @previous_test_case_scenario_outline = current_test_step_source.scenario_outline
        end

        def before_hook(location, result)
          @before_hook_results << Legacy::Ast::HookResult.new(LegacyResultBuilder.new(result), @delayed_messages, @delayed_embeddings)
          @delayed_messages = []
          @delayed_embeddings = []
        end

        def after_hook(location, result)
          # if the scenario has no steps, we can hit this before we've created the scenario printer
          # ideally we should call switch_step_container in before_step_step
          switch_step_container if !@child 
          @child.after_hook Legacy::Ast::HookResult.new(LegacyResultBuilder.new(result), @delayed_messages, @delayed_embeddings)
          @delayed_messages = []
          @delayed_embeddings = []
        end

        def after_step_hook(hook, result)
          line = StepBacktraceLine.new(current_test_step_source.step)
          @child.after_step_hook Legacy::Ast::HookResult.new(LegacyResultBuilder.new(result).
            append_to_exception_backtrace(line), @delayed_messages, @delayed_embeddings)
          @delayed_messages = []
          @delayed_embeddings = []

        end

        def background(node, *)
          @current_test_case_background = node
        end

        def puts(messages)
          @delayed_messages.push *messages
        end

        def embed(src, mime_type, label)
          @delayed_embeddings.push Embedding.new(src, mime_type, label)
        end

        def step(*);end
        def scenario(*);end
        def scenario_outline(*);end
        def examples_table(*);end
        def examples_table_row(*);end
        def feature(*);end

        def after
          @child.after
          formatter.after_feature(node)
          self
        end

        private

        attr_reader :before_hook_results
        private :before_hook_results

        def switch_step_container
          switch_to_child select_step_container(current_test_step_source), current_test_step_source
        end

        def select_step_container(source)
          if source.background
            if same_background_as_previous_test_case?(source)
              HiddenBackgroundPrinter.new(formatter, source.background)
            else
              BackgroundPrinter.new(formatter, source.background, before_hook_results)
            end
          elsif source.scenario
            ScenarioPrinter.new(formatter, source.scenario, before_hook_results)
          elsif source.scenario_outline
            if same_scenario_outline_as_previous_test_case?(source) and @previous_outline_child
              @previous_outline_child
            else
              ScenarioOutlinePrinter.new(formatter, runtime.configuration, source.scenario_outline)
            end
          else
            raise 'unknown step container'
          end
        end

        def same_background_as_previous_test_case?(source)
          source.background == @previous_test_case_background
        end

        def same_scenario_outline_as_previous_test_case?(source)
          source.scenario_outline == @previous_test_case_scenario_outline
        end

        def print_step
          return unless current_test_step_source.step_result
          switch_step_container

          if current_test_step_source.scenario_outline
            @child.examples_table(current_test_step_source.examples_table)
            @child.examples_table_row(current_test_step_source.examples_table_row, before_hook_results)
          end

          if @failed_hidden_background_step
            indent = Indent.new(@child.node)
            step_invocation = @failed_hidden_background_step.build_step_invocation(indent, runtime, messages = [], embeddings = [])
            @child.step_invocation(step_invocation, @failed_hidden_background_step)
            @failed_hidden_background_step = nil
          end

          unless @last_step == current_test_step_source.step
            indent ||= Indent.new(@child.node)
            step_invocation = current_test_step_source.build_step_invocation(indent, runtime, @delayed_messages, @delayed_embeddings)
            runtime.step_visited step_invocation
            @child.step_invocation(step_invocation, current_test_step_source)
            @last_step = current_test_step_source.step
          end
          @delayed_messages = []
          @delayed_embeddings = []
        end

        def switch_to_child(child, source)
          return if @child == child
          if @child
            if from_first_background(@child)
              @first_background_failed = @child.failed?
            elsif from_hidden_background(@child)
              if not @first_background_failed
                @failed_hidden_background_step = @child.get_failed_step_source
              end
              if @previous_outline_child
                @previous_outline_child.after unless same_scenario_outline_as_previous_test_case?(source)
              end
            end
            unless from_scenario_outline_to_hidden_backgroud(@child, child)
              @child.after 
              @previous_outline_child = nil
            else
              @previous_outline_child = @child
            end
          end
          child.before unless to_scenario_outline(child) and same_scenario_outline_as_previous_test_case?(source)
          @child = child
        end

        def from_scenario_outline_to_hidden_backgroud(from, to)
          from.class.name == "Cucumber::Reports::ScenarioOutlinePrinter" and
          to.class.name == "Cucumber::Reports::HiddenBackgroundPrinter"
        end

        def from_first_background(from)
          from.class.name == "Cucumber::Reports::BackgroundPrinter"
        end

        def from_hidden_background(from)
          from.class.name == "Cucumber::Reports::HiddenBackgroundPrinter"
        end

        def to_scenario_outline(to)
          to.class.name == "Cucumber::Reports::ScenarioOutlinePrinter"
        end

        def indented(nasty_old_conflation_of_name_and_description)
          indent = ""
          nasty_old_conflation_of_name_and_description.split("\n").map do |l|
            s = "#{indent}#{l}"
            indent = "  "
            s
          end.join("\n")
        end

      end

      module PrintsAfterHooks
        def after_hook_results
          @after_hook_results ||= Legacy::Ast::NodeCollection.new
        end

        def after_hook(result)
          after_hook_results << result
        end
      end

      # Basic printer used by default
      class AfterHookPrinter
        include Cucumber.initializer(:formatter)

        include PrintsAfterHooks

        def after
          after_hook_results.accept(formatter)
        end
      end

      BackgroundPrinter = Struct.new(:formatter, :node, :before_hook_results) do

        def before
          formatter.before_background node
          formatter.background_name node.keyword, node.legacy_conflated_name_and_description, node.location.to_s, indent.of(node)
          before_hook_results.accept(formatter)
          self
        end

        def after_step_hook(result)
          result.accept formatter
        end

        def step_invocation(step_invocation, source)
          @child ||= StepsPrinter.new(formatter).before
          @child.step_invocation step_invocation
          if source.step_result.status == :failed
            @failed = true
          end
        end

        def after
          @child.after if @child
          formatter.after_background(node)
          self
        end

        def failed?
          @failed
        end

        private

        def indent
          @indent ||= Indent.new(node)
        end
      end

      # Printer to handle background steps for anything but the first scenario in a
      # feature. These steps should not be printed.
      class HiddenBackgroundPrinter < Struct.new(:formatter, :node)
        def get_failed_step_source
          return @source_of_failed_step
        end

        def step_invocation(step_invocation, source)
          if source.step_result.status == :failed
            @source_of_failed_step = source
          end
        end

        def before;self;end
        def after;self;end
        def before_hook(*);end
        def after_hook(*);end
        def after_step_hook(*);end
        def examples_table(*);end
        def after_test_case(*);end
      end

      ScenarioPrinter = Struct.new(:formatter, :node, :before_hook_results) do
        include PrintsAfterHooks

        def before
          formatter.before_feature_element(node)
          Legacy::Ast::Tags.new(node.tags).accept(formatter)
          formatter.scenario_name node.keyword, node.legacy_conflated_name_and_description, node.location.to_s, indent.of(node)
          before_hook_results.accept(formatter)
          self
        end

        def step_invocation(step_invocation, source)
          @child ||= StepsPrinter.new(formatter).before
          @child.step_invocation step_invocation
          @last_step_result = source.step_result
        end

        def after_step_hook(result)
          result.accept formatter
        end

        def after_test_case(*args)
          after
        end

        def after
          return if @done
          @child.after if @child
          # TODO - the last step result might not accurately reflect the
          # overall scenario result.
          scenario = last_step_result.scenario(node.name, node.location)
          after_hook_results.accept(formatter)
          formatter.after_feature_element(scenario)
          @done = true
          self
        end

        private

        def last_step_result
          @last_step_result || LegacyResultBuilder.new(Core::Test::Result::Unknown.new)
        end

        def indent
          @indent ||= Indent.new(node)
        end
      end

      StepsPrinter = Struct.new(:formatter) do
        def before
          formatter.before_steps(nil)
          self
        end

        def step_invocation(step_invocation)
          steps << step_invocation
          step_invocation.accept(formatter)
          self
        end

        def after
          formatter.after_steps(steps)
          self
        end

        private

        def steps
          @steps ||= Legacy::Ast::StepInvocations.new
        end

      end

      ScenarioOutlinePrinter = Struct.new(:formatter, :configuration, :node) do
        extend Forwardable
        def_delegators :@child, :after_hook, :after_step_hook

        def before
          formatter.before_feature_element(node)
          Legacy::Ast::Tags.new(node.tags).accept(formatter)
          formatter.scenario_name node.keyword, node.legacy_conflated_name_and_description, node.location.to_s, indent.of(node)
          OutlineStepsPrinter.new(formatter, configuration, indent).print(node)
          self
        end

        def step_invocation(step_invocation, source)
          node, result = source.step, source.step_result
          @last_step_result = result
          @child.step_invocation(step_invocation, source)
        end

        def examples_table(examples_table)
          @child ||= ExamplesArrayPrinter.new(formatter, configuration).before
          @child.examples_table(examples_table)
        end

        def examples_table_row(node, before_hook_results)
          @child.examples_table_row(node, before_hook_results)
        end

        def after_test_case
          @child.after_test_case
        end

        def after
          @child.after if @child
          # TODO - the last step result might not accurately reflect the
          # overall scenario result.
          scenario_outline = last_step_result.scenario_outline(node.name, node.location)
          formatter.after_feature_element(scenario_outline)
          self
        end

        private

        def last_step_result
          @last_step_result || Core::Test::Result::Unknown.new
        end

        def indent
          @indent ||= Indent.new(node)
        end
      end

      OutlineStepsPrinter = Struct.new(:formatter, :configuration, :indent, :outline) do
        def print(node)
          node.describe_to self
          steps_printer.after
        end

        def scenario_outline(node, &descend)
          descend.call(self)
        end

        def outline_step(step)
          step_match = NoStepMatch.new(step, step.name)
          step_invocation = LegacyResultBuilder.new(Core::Test::Result::Skipped.new).
            step_invocation(step_match, step, indent, background = nil, configuration, messages = [], embeddings = [])
          steps_printer.step_invocation step_invocation
        end

        def examples_table(*);end

        private

        def steps_printer
          @steps_printer ||= StepsPrinter.new(formatter).before
        end
      end

      ExamplesArrayPrinter = Struct.new(:formatter, :configuration) do
        extend Forwardable
        def_delegators :@child, :step_invocation, :after_hook, :after_step_hook, :after_test_case, :examples_table_row

        def before
          formatter.before_examples_array(:examples_array)
          self
        end

        def examples_table(examples_table)
          return if examples_table == @current
          @child.after if @child
          @child = ExamplesTablePrinter.new(formatter, configuration, examples_table).before
          @current = examples_table
        end

        def after
          @child.after if @child
          formatter.after_examples_array
          self
        end
      end

      ExamplesTablePrinter = Struct.new(:formatter, :configuration, :node) do
        extend Forwardable
        def_delegators :@child, :step_invocation, :after_hook, :after_step_hook, :after_test_case

        def before
          formatter.before_examples(node)
          formatter.examples_name(node.keyword, node.legacy_conflated_name_and_description)
          formatter.before_outline_table(legacy_table)
          if !configuration.expand?
            HeaderTableRowPrinter.new(formatter, ExampleTableRow.new(node.header), Legacy::Ast::Node.new).before.after
          end
          self
        end

        def examples_table_row(examples_table_row, before_hook_results)
          return if examples_table_row == @current
          @child.after if @child
          row = ExampleTableRow.new(examples_table_row)
          if !configuration.expand?
            @child = TableRowPrinter.new(formatter, row, before_hook_results).before
          else
            @child = ExpandTableRowPrinter.new(formatter, row, before_hook_results).before
          end
          @current = examples_table_row
        end

        def after_test_case(*args)
          @child.after_test_case
        end

        def after
          @child.after if @child
          formatter.after_outline_table(node)
          formatter.after_examples(node)
          self
        end

        private

        def legacy_table
          LegacyTable.new(node)
        end

        class ExampleTableRow < SimpleDelegator
          def dom_id
            file_colon_line.gsub(/[\/\.:]/, '_')
          end
        end

        LegacyTable = Struct.new(:node) do
          def col_width(index)
            max_width = FindMaxWidth.new(index)
            node.describe_to max_width
            max_width.result
          end

          require 'gherkin/formatter/escaping'
          FindMaxWidth = Struct.new(:index) do
            include ::Gherkin::Formatter::Escaping

            def examples_table(table, &descend)
              @result = char_length_of(table.header.values[index])
              descend.call(self)
            end

            def examples_table_row(row, &descend)
              width = char_length_of(row.values[index])
              @result = width if width > result
            end

            def result
              @result ||= 0
            end

            private
            def char_length_of(cell)
              escape_cell(cell).unpack('U*').length
            end
          end
        end
      end

      class TableRowPrinterBase < Struct.new(:formatter, :node, :before_hook_results)
        include PrintsAfterHooks

        def after_step_hook(result)
          @after_step_hook_result ||= []
          @after_step_hook_result.push result
        end

        def after_test_case(*args)
          after
        end

        private

        def indent
          :not_needed
        end

        def legacy_table_row
          LegacyExampleTableRow.new(exception, @status, node.values, node.location)
        end

        def exception
          return nil unless @failed_step
          @failed_step.exception
        end
      end

      class HeaderTableRowPrinter < TableRowPrinterBase
        def before
          formatter.before_table_row(node)
          self
        end

        def after
          node.values.each do |value|
            formatter.before_table_cell(value)
            formatter.table_cell_value(value, :skipped_param)
            formatter.after_table_cell(value)
          end
          formatter.after_table_row(legacy_table_row)
          self
        end
      end


      class TableRowPrinter < TableRowPrinterBase
        def before
          before_hook_results.accept(formatter)
          formatter.before_table_row(node)
          self
        end

        def step_invocation(step_invocation, source)
          result = source.step_result
          step_invocation.messages.each { |message| formatter.puts(message) }
          step_invocation.embeddings.each { |embedding| embedding.send_to_formatter(formatter) }
          @failed_step = step_invocation if result.status == :failed
          @status = step_invocation.status unless already_failed?
        end

        def after
          return if @done
          @child.after if @child
          node.values.each do |value|
            formatter.before_table_cell(value)
            formatter.table_cell_value(value, @status || :skipped)
            formatter.after_table_cell(value)
          end
          formatter.after_table_row(legacy_table_row)
          @after_step_hook_result.each { |result| result.accept formatter } if @after_step_hook_result
          after_hook_results.accept(formatter)
          @done = true
          self
        end

        private

        def already_failed?
          @status == :failed || @status == :undefined || @status == :pending
        end
      end

      class ExpandTableRowPrinter < TableRowPrinterBase
        def before
          before_hook_results.accept(formatter)
          self
        end

        def step_invocation(step_invocation, source)
          result = source.step_result
          @table_row ||= legacy_table_row
          step_invocation.indent.record_width_of(@table_row)
          if !@scenario_name_printed
            print_scenario_name(step_invocation, @table_row)
            @scenario_name_printed = true
          end
          step_invocation.accept(formatter)
          @failed_step = step_invocation if result.status == :failed
          @status = step_invocation.status unless @status == :failed
        end

        def after
          return if @done
          @child.after if @child
          @after_step_hook_result.each { |result| result.accept formatter } if @after_step_hook_result
          after_hook_results.accept(formatter)
          @done = true
          self
        end

        private

        def print_scenario_name(step_invocation, table_row)
          formatter.scenario_name table_row.keyword, table_row.name, node.location.to_s, step_invocation.indent.of(table_row)
        end
      end

      LegacyExampleTableRow = Struct.new(:exception, :status, :cells, :location) do
        def name
          '| ' + cells.join(' | ') + ' |'
        end

        def failed?
          status == :failed
        end

        def line
          location.line
        end

        def keyword
          # This method is only called when used for the scenario name line with
          # the expand option, and on that line the keyword is "Scenario"
          "Scenario"
        end
      end

      class Indent
        def initialize(node)
          @widths = []
          node.describe_to(self)
        end

        [:background, :scenario, :scenario_outline].each do |node_name|
          define_method(node_name) do |node, &descend|
          record_width_of node
          descend.call(self)
          end
        end

        [:step, :outline_step].each do |node_name|
          define_method(node_name) do |node|
            record_width_of node
          end
        end

        def examples_table(*); end
        def examples_table_row(*); end

        def of(node)
          # The length of the instantiated steps in --expand mode are currently
          # not included in the calculation of max => make sure to return >= 1
          [1, max - node.name.length - node.keyword.length].max
        end

        def record_width_of(node)
          @widths << node.keyword.length + node.name.length + 1
        end

        private

        def max
          @widths.max
        end
      end

      class LegacyResultBuilder
        attr_reader :status
        def initialize(result)
          @result = result
          @result.describe_to(self)
        end

        def passed
          @status = :passed
        end

        def failed
          @status = :failed
        end

        def undefined
          @status = :undefined
        end

        def skipped
          @status = :skipped
        end

        def pending(exception, *)
          @exception = exception
          @status = :pending
        end

        def exception(exception, *)
          @exception = exception
        end

        def append_to_exception_backtrace(line)
          @exception.set_backtrace(@exception.backtrace + [line.to_s]) if @exception
          return self
        end

        def duration(*); end

        def step_invocation(step_match, step, indent, background, configuration, messages, embeddings)
          Legacy::Ast::StepInvocation.new(step_match, @status, step_exception(step, configuration), indent, background, step, messages, embeddings)
        end

        def scenario(name, location)
          Legacy::Ast::Scenario.new(@status, name, location)
        end

        def scenario_outline(name, location)
          Legacy::Ast::ScenarioOutline.new(@status, name, location)
        end

        def describe_exception_to(formatter)
          formatter.exception(filtered_exception, @status) if @exception
        end

        private

        def step_exception(step, configuration)
          return filtered_step_exception(step) if @exception
          return nil unless @status == :undefined && configuration.strict?
          @exception = Cucumber::Undefined.from(@result, step.name)
          filtered_step_exception(step)
        end

        def filtered_exception
          BacktraceFilter.new(@exception.dup).exception
        end

        def filtered_step_exception(step)
          exception = filtered_exception
          exception.backtrace << StepBacktraceLine.new(step).to_s
          return exception
        end
      end

    end

    class StepBacktraceLine < Struct.new(:step)
      def to_s
        step.backtrace_line
      end
    end

    class BacktraceFilter
      BACKTRACE_FILTER_PATTERNS = \
        [/vendor\/rails|lib\/cucumber|bin\/cucumber:|lib\/rspec|gems\/|minitest|test\/unit|.gem\/ruby|lib\/ruby/]
      if(::Cucumber::JRUBY)
        BACKTRACE_FILTER_PATTERNS << /org\/jruby/
      end
      PWD_PATTERN = /#{::Regexp.escape(::Dir.pwd)}\//m

      def initialize(exception)
        @exception = exception
      end

      def exception
        return @exception if ::Cucumber.use_full_backtrace
        @exception.backtrace.each{|line| line.gsub!(PWD_PATTERN, "./")}

        filtered = (@exception.backtrace || []).reject do |line|
          BACKTRACE_FILTER_PATTERNS.detect { |p| line =~ p }
        end

        if ::ENV['CUCUMBER_TRUNCATE_OUTPUT']
          # Strip off file locations
          filtered = filtered.map do |line|
            line =~ /(.*):in `/ ? $1 : line
          end
        end

        @exception.set_backtrace(filtered)
        @exception
      end
    end


    # Adapters to pass to the legacy API formatters that provide the interface
    # of the old AST classes
    module Legacy
      module Ast

        # Acts as a null object, or a base class
        class Node
          def initialize(node = nil)
            @node = node
          end

          def accept(formatter)
          end

          attr_reader :node
          private :node
        end

        class NodeCollection
          def initialize
            @children = []
          end

          def accept(formatter)
            @children.each { |child| child.accept(formatter) }
          end

          def <<(child)
            @children << child
          end
        end

        Comments = Struct.new(:comments) do
          def accept(formatter)
            return if comments.empty?
            formatter.before_comment comments
            comments.each do |comment|
              formatter.comment_line comment.to_s.strip
            end
          end
        end

        class HookResult
          def initialize(result, messages, embeddings)
            @result, @messages, @embeddings = result, messages, embeddings
            @already_accepted = false
          end

          def accept(formatter)
            unless @already_accepted
              @messages.each { |message| formatter.puts(message) }
              @embeddings.each { |embedding| embedding.send_to_formatter(formatter) }
              @result.describe_exception_to(formatter)
              @already_accepted = true
            end
            self
          end
        end

        StepInvocation = Struct.new(:step_match,
                                    :status,
                                    :exception,
                                    :indent,
                                    :background,
                                    :step,
                                    :messages,
                                    :embeddings) do
          extend Forwardable

          def_delegators :step, :keyword, :name, :multiline_arg, :location, :gherkin_statement

          def accept(formatter)
            formatter.before_step(self)
            messages.each { |message| formatter.puts(message) }
            embeddings.each { |embedding| embedding.send_to_formatter(formatter) }
            formatter.before_step_result *step_result_attributes
            print_step_name(formatter)
            Legacy::Ast::MultilineArg.for(multiline_arg).accept(formatter)
            print_exception(formatter)
            formatter.after_step_result *step_result_attributes
            formatter.after_step(self)
          end

          def step_result_attributes
            [keyword, step_match, multiline_arg, status, exception, source_indent, background, file_colon_line]
          end

          def failed?
            status != :passed
          end

          def passed?
            status == :passed
          end

          def dom_id

          end

          def actual_keyword
            # TODO: This should return the keyword for the snippet
            # `actual_keyword` translates 'And', 'But', etc. to 'Given', 'When',
            # 'Then' as appropriate
            "Given"
          end

          def file_colon_line
            location.to_s
          end

          def backtrace_line
            step_match.backtrace_line
          end

          def step_invocation
            self
          end

          private

          def source_indent
            indent.of(self)
          end

          def print_step_name(formatter)
            formatter.step_name(
              keyword,
              step_match,
              status,
              source_indent,
              background,
              location.to_s)
          end

          def print_exception(formatter)
            return unless exception
            raise exception if ENV['FAIL_FAST']
            formatter.exception(exception, status)
          end
        end

        class StepInvocations < Array
          def failed?
            any?(&:failed?)
          end

          def passed?
            all?(&:passed?)
          end

          def status
            return :passed if passed?
            failed_step.status
          end

          def exception
            failed_step.exception if failed_step
          end

          private

          def failed_step
            detect(&:failed?)
          end
        end

        class DataTableRow
          def initialize(row, line)
            @values = row
            @line = line
          end

          def dom_id
            "row_#{line}"
          end

          def accept(formatter)
            formatter.before_table_row(self)
            values.each do |value|
              formatter.before_table_cell(value)
              formatter.table_cell_value(value, status)
              formatter.after_table_cell(value)
            end
            formatter.after_table_row(self)
          end

          def status
            :skipped
          end

          def exception
            nil
          end

          attr_reader :values, :line
          private :values, :line
        end

        class LegacyTableRow < DataTableRow
          def accept(formatter)
            formatter.before_table_row(self)
            values.each do |value|
              formatter.before_table_cell(value.value)
              formatter.table_cell_value(value.value, value.status)
              formatter.after_table_cell(value.value)
            end
            formatter.after_table_row(self)
          end
        end

        Tags = Struct.new(:tags) do
          def accept(formatter)
            formatter.before_tags tags
            tags.each do |tag|
              formatter.tag_name tag.name
            end
            formatter.after_tags tags
          end
        end

        Scenario = Struct.new(:status, :name, :location) do
          def backtrace_line(step_name = "#{name}", line = self.location.line)
            "#{location.on_line(line)}:in `#{step_name}'"
          end

          def failed?
            :failed == status
          end

          def line
            location.line
          end
        end

        ScenarioOutline = Struct.new(:status, :name, :location) do
          def backtrace_line(step_name = "#{name}", line = self.location.line)
            "#{location.on_line(line)}:in `#{step_name}'"
          end

          def failed?
            :failed == status
          end

          def line
            location.line
          end
        end

        module MultilineArg
          class << self
            def for(node)
              Builder.new(node).result
            end
          end

          class Builder
            def initialize(node)
              node.describe_to(self)
            end

            def doc_string(node)
              @result = DocString.new(node)
            end

            def data_table(node)
              @result = DataTable.new(node)
            end

            def legacy_table(node)
              @result = LegacyTable.new(node)
            end

            def result
              @result || Node.new(nil)
            end
          end

          class DocString < Node
            def accept(formatter)
              formatter.before_multiline_arg node
              formatter.doc_string(node)
              formatter.after_multiline_arg node
            end
          end

          class DataTable < Cucumber::MultilineArgument::DataTable
            def node
              @ast_table
            end

            def accept(formatter)
              formatter.before_multiline_arg self
              node.raw.each_with_index do |row, index|
                line = node.location.line + index
                Legacy::Ast::DataTableRow.new(row, line).accept(formatter)
              end
              formatter.after_multiline_arg self
            end
          end
        end

        class LegacyTable < SimpleDelegator
          def accept(formatter)
            formatter.before_multiline_arg self
            cells_rows.each_with_index do |row, index|
              line = location.line + index
              Legacy::Ast::LegacyTableRow.new(row, line).accept(formatter)
            end
            formatter.after_multiline_arg self
          end
        end

        Features = Struct.new(:duration)

      end

    end
  end
end
