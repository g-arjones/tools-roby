
# simplecov must be loaded FIRST. Only the files required after it gets loaded
# will be profiled !!!
if ENV['TEST_ENABLE_COVERAGE'] == '1'
    ENV['TEST_ENABLE_COVERAGE'] = '0'
    begin
        require 'simplecov'
        SimpleCov.start do
            add_filter "/test/"
        end
    rescue LoadError
        require 'roby'
        Roby.warn "coverage is disabled because the 'simplecov' gem cannot be loaded"
    rescue Exception => e
        require 'roby'
        Roby.warn "coverage is disabled: #{e.message}"
    end
end

require 'minitest/autorun'
require 'flexmock/minitest'
require 'roby'
require 'roby/test/common'
require 'roby/test/minitest_helpers'
require 'roby/tasks/simple'
require 'roby/test/tasks/empty_task'

module Roby
    module Test
    # This module is extending Test to be able to run tests using the normal
    # testrb command. It is meant to be used to test libraries (e.g. Roby
    # itself) as, in complex Roby applications, the setup and teardown steps
    # would be very expensive.
    #
    # @see Test
    module Self
        include Roby::Test
        include Roby::Test::Assertions

        def setup
            Roby.app.log['server'] = false
            Roby.app.auto_load_models = false
            Roby.app.plugins_enabled = false
            Roby.app.testing = true
            Roby.app.setup
            Roby.app.prepare

            @plan    = ExecutablePlan.new
            @control = DecisionControl.new
            if !plan.execution_engine
                ExecutionEngine.new(@plan, @control)
            end

            Roby.app.public_logs = false

            super

	    # Save and restore some arrays
	    save_collection Roby::ExecutionEngine.propagation_handlers
	    save_collection Roby::ExecutionEngine.external_events_handlers
	    save_collection Roby::Plan.structure_checks
	    Roby.app.abort_on_exception = false
	    Roby.app.abort_on_application_exception = true
        end

        def teardown
            begin
                super
            rescue Exception => e
                teardown_failure = e
            end
            Roby.app.cleanup
            State.clear
            State.clear_model
            Conf.clear
            Conf.clear_model

        ensure
            if teardown_failure
                raise teardown_failure
            end
        end
    end
    end
    SelfTest = Test::Self
end

module Minitest
    class Test
        include Roby::Test::Self
        prepend Roby::Test::MinitestHelpers
    end
end

