module Roby
    module Coordination
        module Models
            # Definition of a single fault handler in a FaultResponseTable
            module FaultHandler
                include Actions
                include Script

                # @return [FaultResponseTable] the table this handler is part of
                def fault_response_table; action_interface end
                # @return [Queries::ExecutionExceptionMatcher] the object
                #   defining for which faults this handler should be activated
                inherited_single_value_attribute(:execution_exception_matcher) { Queries.none }
                # @return [Integer] this handler's priority
                inherited_single_value_attribute(:priority) { 0 }
                # @return [:missions,:actions,:origin] the fault response
                #   location
                inherited_single_value_attribute(:response_location) { :actions }
                # @return [Boolean] if true, the action location will be retried
                #   after the fault response table, otherwise whatever should
                #   happen will happen (other error handling, ...)
                inherited_single_value_attribute(:__try_again) { false }
                # @return [Boolean] if true, the last action of the response
                #   will be to retry whichever action/missions/tasks have been
                #   interrupted by the fault
                def try_again?; !!__try_again end
                # @return [#instanciate] an object that allows to create the
                #   toplevel task of the fault response
                inherited_single_value_attribute :action
                # @return [Task] a replacement task for the response location,
                #   once the fault handler is finished
                attr_reader :replacement

                def locate_on_missions
                    response_location :missions
                    self
                end

                def locate_on_actions
                    response_location :actions
                    self
                end

                def locate_on_origin
                    response_location :origin
                    self
                end

                # Try the repaired action again when the fault handler
                # successfully finishes
                #
                # It can be called anytime in the script, but will have an
                # effect only at the end of the fault handler
                def try_again
                    __try_again(true)
                end

                # Replace the response's location by this task when the fault
                # handler script is finished
                #
                # It can be called anytime in the script, but will be performed
                # only at the end of the handler
                #
                # @raise ArgumentError if there is already a replacement task
                def replace_by(task)
                    if @replacement
                        raise ArgumentError, "there is already a replacement task defined"
                    end
                    @replacement = validate_or_create_task(task)
                end

                def find_response_locations(origin)
                    if response_location == :origin
                        return [origin].to_set
                    end

                    predicate =
                        if response_location == :missions
                            proc { |t| t.mission? && t.running? }
                        elsif response_location == :actions
                            proc { |t| t.running? && t.planning_task && t.planning_task.kind_of?(Roby::Actions::Task) }
                        end

                    result = Set.new
                    Roby::TaskStructure::Dependency.reverse.each_dfs(origin, BGL::Graph::TREE) do |_, to, _|
                        if predicate.call(to)
                            result << to
                            Roby::TaskStructure::Dependency.prune
                        end
                    end
                    result
                end

                def activate(exception, arguments = Hash.new)
                    locations = find_response_locations(exception.origin)
                    if locations.empty?
                        Roby.warn "#{self} did match an exception, but the response location #{response_location} does not match anything"
                        return
                    end

                    plan = exception.origin.plan

                    # Create the response task
                    plan.add(response_task = FaultHandlingTask.new)
                    response_task.fault_handler = self
                    new(action_interface, response_task, arguments)
                    response_task.start!
                    locations.each do |task|
                        # Mark :stop as handled by the response task and kill
                        # the task
                        #
                        # In addition, if origin == task, we need to handle the
                        # error events as well
                        task.add_error_handler response_task,
                            [task.stop_event.to_execution_exception_matcher, execution_exception_matcher].to_set
                    end
                    locations.each do |task|
                        # This should not be needed. However, the current GC
                        # implementation in ExecutionEngine does not stop at
                        # finished tasks, and therefore would not GC the
                        # underlying tasks
                        task.remove_children(Roby::TaskStructure::Dependency)
                        task.stop! if task.running?
                    end
                end
            end
        end
    end
end
