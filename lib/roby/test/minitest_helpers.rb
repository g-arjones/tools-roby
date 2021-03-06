module Roby
    module Test
        # Handlers for minitest-based tests
        #
        # They mainly "tune" the default minitest behaviour to match some of the
        # Roby idioms as e.g. using pretty-print to format exception messages
        module MinitestHelpers
            def roby_find_matching_exception(expected, exception)
                queue = [exception]
                seen  = Set.new
                while !queue.empty?
                    e = queue.shift
                    next if seen.include?(e)
                    seen << e
                    if expected.any? { |expected_e| e.kind_of?(expected_e) }
                        return e
                    end
                    if e.respond_to?(:original_exceptions)
                        queue.concat(e.original_exceptions)
                    end
                end
                nil
            end

            def assert_raises(*exp, &block)
                if plan.executable?
                    # Avoid having it displayed by the execution engine. We're going
                    # to display any unexpected exception anyways
                    display_exceptions_enabled, plan.execution_engine.display_exceptions =
                        plan.execution_engine.display_exceptions?, false
                end

                msg = exp.pop if String === exp.last

                # The caller expects a non-Roby exception. It is going to be
                # wrapped in a LocalizedError, so make sure we properly
                # process it
                begin
                    yield
                rescue *exp => e
                    assert_exception_can_be_pretty_printed(e)
                    return e
                rescue Roby::UserExceptionWrapper => wrapper_e
                    assert_exception_can_be_pretty_printed(wrapper_e)
                    all = Roby.flatten_exception(wrapper_e)
                    if actual_e = all.find { |e| exp.any? { |expected_e| e.kind_of?(expected_e) } }
                        return actual_e
                    end
                    actually_caught = roby_exception_to_string(*all)
                    flunk("#{exp.map(&:to_s).join(", ")} exceptions expected, not #{wrapper_e.class} #{actually_caught}")
                rescue Exception => e
                    assert_exception_can_be_pretty_printed(e)
                    actually_caught = roby_exception_to_string(e)
                    flunk("#{exp.map(&:to_s).join(", ")} exceptions expected, not #{e.class} #{actually_caught}")
                end
                flunk("#{exp.map(&:to_s).join(", ")} exceptions expected but received nothing")

            ensure
                if plan.executable?
                    plan.execution_engine.display_exceptions =
                        display_exceptions_enabled
                end
            end

            def roby_exception_to_string(*queue)
                msg = ""
                seen = Set.new
                while e = queue.shift
                    next if seen.include?(e)
                    seen << e
                    e_bt = Minitest.filter_backtrace(e.backtrace).join "\n    "
                    msg << "\n\n" << Roby.format_exception(e).join("\n") +
                        "\n    #{e_bt}"

                    queue.concat(e.original_exceptions) if e.respond_to?(:original_exceptions)
                end
                msg
            end

            def to_s
                if !error?
                    super
                else
                    failures.map { |failure|
                        bt = Minitest.filter_backtrace(failure.backtrace).join "\n    "
                        msg = 
                            if failure.kind_of?(Minitest::UnexpectedError)
                                roby_exception_to_string(failure.exception)
                            else
                                failure.message
                            end
                        "#{failure.result_label}:\n#{self.location}:\n#{msg}\n"
                    }.join "\n"
                end
            end

            def capture_exceptions
                super do
                    begin
                        yield
                    rescue SynchronousEventProcessingMultipleErrors => aggregate_e
                        exceptions = aggregate_e.errors.map do |execution_exception, _|
                            execution_exception.exception
                        end

                        # Try to be smart and to only keep the toplevel
                        # exceptions
                        filter_execution_exceptions(exceptions).each do |e|
                            case e
                            when Assertion
                                self.failures << e
                            else
                                self.failures << Minitest::UnexpectedError.new(e)
                            end
                        end
                    end
                end
            end

            def filter_execution_exceptions(exceptions)
                included_in_another = exceptions.
                    inject(Set.new) do |s, e|
                        s.merge(Roby.flatten_exception(e) - [e])
                    end
                exceptions.find_all { |e| !included_in_another.include?(e) }
            end

            def exception_details e, msg
                [
                    "#{msg}",
                    "Class: <#{e.class}>",
                    "Message: <#{e.message.inspect}>",
                    "Pretty-print:",
                    *Roby.format_exception(e),
                    "---Backtrace---",
                    "#{Minitest.filter_backtrace(e.backtrace).join("\n")}",
                    "---------------",
                ].join "\n"
            end
        end
    end
end

