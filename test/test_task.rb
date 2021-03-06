require 'roby/test/self'
require 'roby/tasks/group'

module Roby
    describe Task do
        describe "the argument handling" do
            describe "__assign_arguments__" do
                let(:task_m) do
                    Task.new_submodel do
                        argument :high_level_arg
                        argument :low_level_arg
                        def high_level_arg=(value)
                            arguments[:low_level_arg] = 10
                            arguments[:high_level_arg] = 10
                        end
                    end
                end

                it "allows for the same argument to be set twice to the same value" do
                    task = task_m.new
                    task.assign_arguments(low_level_arg: 10, high_level_arg: 10)
                    assert_equal 10, task.low_level_arg
                    assert_equal 10, task.high_level_arg
                end
                it "raises if the same argument is set twice to different values" do
                    task = task_m.new
                    assert_raises(ArgumentError) do
                        task.assign_arguments(low_level_arg: 20, high_level_arg: 10)
                    end
                end
                it "properly overrides a delayed argument" do
                    # There was a bug in which a delayed argument would not be
                    # overriden because it would be set when the first argument
                    # was handled and then reset when the second was
                    delayed_arg = flexmock
                    delayed_arg.should_receive(:evaluate_delayed_argument).with(task_m).and_return(10)
                    task = task_m.new(high_level_arg: delayed_arg)
                    task.assign_arguments(high_level_arg: 10, low_level_arg: 10)
                    assert_equal 10, task.high_level_arg
                    assert_equal 10, task.low_level_arg
                end

                it "does parallel-assignment of arguments given to it at initialization" do
                    flexmock(task_m).new_instances.
                        should_receive(:__assign_arguments__).
                        with(high_level_arg: 10, low_level_arg: 10)

                    plan.add(task = task_m.new(high_level_arg: 10, low_level_arg: 10))
                end

                it "does parallel-assignment of delayed arguments in #freeze_delayed_arguments" do
                    delayed_arg = flexmock
                    delayed_arg.should_receive(:evaluate_delayed_argument).with(task_m).and_return(10)

                    plan.add(task = task_m.new(high_level_arg: delayed_arg))
                    flexmock(task).should_receive(:assign_arguments).
                        once.with(high_level_arg: 10)
                    task.freeze_delayed_arguments
                end
            end
        end

        describe "#last_event" do
            attr_reader :task
            before do
                plan.add(@task = Roby::Tasks::Simple.new)
            end
            it "returns nil if no event has ever been emitted" do
                assert_equal nil, task.last_event
            end
            it "returns the last emitted event if some where emitted" do
                task.start_event.emit
                assert_equal task.start_event.last, task.last_event
                task.stop_event.emit
                assert_equal task.stop_event.last, task.last_event
            end
        end

        describe "abstract-ness" do
            it "is not abstract if its model is not" do
                plan.add(task = Roby::Task.new_submodel.new)
                assert !task.abstract?
            end
            it "is abstract if its model is" do
                plan.add(task = Roby::Task.new_submodel { abstract }.new)
                assert task.abstract?
            end
            it "is overriden with #abstract=" do
                plan.add(task = Roby::Task.new_submodel { abstract }.new)
                task.abstract = false
                assert !task.abstract?
                task.abstract = true
                assert task.abstract?
            end
            it "is not executable if it is abstract" do
                plan.add(task = Roby::Task.new_submodel { abstract }.new)
                task.abstract = false
                assert task.executable?
                task.abstract = true
                assert !task.executable?
            end
        end

        describe "transaction proxies" do
            subject { plan.add(t = Roby::Task.new); t }

            it "does not wrap any events on a standalone task" do
                plan.in_transaction do |trsc|
                    trsc[subject].each_event.empty?
                end
            end

            it "wraps events that have relations outside the task itself" do
                root, task = prepare_plan add: 2
                root.start_event.signals task.start_event
                plan.in_transaction do |trsc|
                    assert_equal [:start], trsc[task].each_event.map(&:symbol)
                end
            end

            it "wraps events on demand" do
                plan.in_transaction do |trsc|
                    p = trsc[subject]
                    assert trsc.task_events.empty?
                    start = p.start_event
                    refute_same subject.start_event, start
                    assert_equal [start], p.each_event.to_a
                    assert_same start, p.start_event
                    assert trsc.has_task_event?(p.start_event)
                end
            end

            it "copies copy_on_replace handlers from the plan even if the source generator is not wrapped" do
                source, target = prepare_plan add: 2
                source.start_event.on(on_replace: :copy) { }
                plan.in_transaction do |trsc|
                    p_source, p_target = trsc[source], trsc[target]
                    trsc.replace_task(p_source, p_target)
                    assert_equal [:start], p_target.each_event.map(&:symbol)
                    trsc.commit_transaction
                end
                assert_equal source.start_event.handlers, target.start_event.handlers
            end

            it "copies copy_on_replace handlers from the plan if the source generator is wrapped" do
                source, target = prepare_plan add: 2
                source.start_event.on(on_replace: :copy) { }
                plan.in_transaction do |trsc|
                    p_source, p_target = trsc[source], trsc[target]
                    p_source.start_event
                    trsc.replace_task(p_source, p_target)
                    assert_equal [:start], p_target.each_event.map(&:symbol)
                    trsc.commit_transaction
                end
                assert_equal source.start_event.handlers, target.start_event.handlers
            end

            it "propagates the argument's static flag from plan to transaction" do
                plan.add(task = Tasks::Simple.new(id: DefaultArgument.new(10)))
                plan.in_transaction do |t|
                    assert !t[task].arguments.static?
                end
            end
        end
        
        describe "#instanciate_model_event_relations" do
            def self.common_instanciate_model_event_relations_behaviour
                it "adds a precedence link between the start event and all root intermediate events" do
                    # Add one root that forwards to something and one standalone
                    # event
                    plan.add(task = task_m.new)
                    assert(task.start_event.child_object?(
                        task.ev1_event, Roby::EventStructure::Precedence))
                    assert(!task.start_event.child_object?(
                        task.ev2_event, Roby::EventStructure::Precedence))
                    assert(task.start_event.child_object?(
                        task.ev3_event, Roby::EventStructure::Precedence))
                end

                it "adds a precedence link between the leaf intermediate events and the root terminal events" do
                    task.each_event do |ev|
                        if ev.terminal?
                            assert(!task.ev1_event.child_object?(
                                ev, Roby::EventStructure::Precedence))
                        end
                    end
                    [:success, :aborted, :internal_error].each do |terminal|
                        assert(task.ev2_event.child_object?(
                            task.event(terminal), Roby::EventStructure::Precedence), "ev2 is not marked as preceding #{terminal}")
                        assert(task.ev3_event.child_object?(
                            task.event(terminal), Roby::EventStructure::Precedence), "ev3 is not marked as preceding #{terminal}")
                    end
                end
            end

            describe "start is not terminal" do
                let(:task_m) do
                    Roby::Tasks::Simple.new_submodel do
                        event :ev1
                        event :ev2
                        event :ev3
                        forward :ev1 => :ev2
                    end
                end
            end

            describe "start is terminal" do
                let(:task_m) do
                    Roby::Tasks::Simple.new_submodel do
                        event :ev1
                        event :ev2
                        event :ev3
                        forward :ev1 => :ev2
                        forward :start => :stop
                    end
                end
            end
        end

        describe "#execute" do
            let(:recorder) { flexmock }

            it "delays the block execution until the task starts" do
                plan.add(task = Roby::Tasks::Simple.new)
                task.execute do |t|
                    recorder.execute_called(t)
                end
                recorder.should_receive(:execute_called).with(task).once
                task.start!
            end

            it "yields in the next cycle on running tasks" do
                plan.add(task = Roby::Tasks::Simple.new)
                task.start!
                task.execute do |t|
                    recorder.execute_called(t)
                end
                recorder.should_receive(:execute_called).with(task).once
                process_events
            end

            describe "on_replace: :copy" do
                attr_reader :task, :replacement
                before do
                    plan.add(@task = Roby::Tasks::Simple.new(id: 1))
                    @replacement = Roby::Tasks::Simple.new(id: 1)
                    task.execute(on_replace: :copy) { |c| recorder.called(c) }
                    recorder.should_receive(:called).with(task).once
                    recorder.should_receive(:called).with(replacement).once
                end
                it "copies the handler on a replacement done in the plan" do
                    plan.add(replacement)
                    plan.replace_task(task, replacement)
                    replacement.start!
                    task.start!
                end
                it "copies the handlers on a replacement added and done in a transaction" do
                    PlanObject.debug_finalization_place = true
                    plan.in_transaction do |trsc|
                        trsc.add(replacement)
                        trsc.replace_task(trsc[task], replacement)
                        trsc.commit_transaction
                    end
                    replacement.start!
                    task.start!
                end
                it "copies the handlers on a replacement added in the plan and done in a transaction" do
                    plan.add(replacement)
                    plan.in_transaction do |trsc|
                        trsc.replace_task(trsc[task], trsc[replacement])
                        trsc.commit_transaction
                    end
                    replacement.start!
                    task.start!
                end
            end
        end

        def self.it_matches_common_replace_behaviour
            it "does not touch the target relations" do
                root, task0, task1 = prepare_plan add: 3
                root.depends_on task1
                replace(task0, task1)
                assert root.depends_on?(task1)
            end

            it "moves parent task relations" do
                root, task0, task1 = prepare_plan add: 3
                root.depends_on task0
                replace(task0, task1)
                assert !root.depends_on?(task0)
                assert root.depends_on?(task1)
            end

            it "only copies relations that have a copy_on_write flag set" do
                flexmock(Roby::TaskStructure::Dependency).should_receive(:copy_on_replace?).and_return(true)
                flexmock(plan.task_relation_graph_for(Roby::TaskStructure::Dependency)).
                    should_receive(:copy_on_replace?).and_return(true)
                root, task0, task1 = prepare_plan add: 3
                root.depends_on task0
                replace(task0, task1)
                assert root.depends_on?(task0)
                assert root.depends_on?(task1)
            end

            it "ignores strong relations" do
                flexmock(Roby::TaskStructure::Dependency).should_receive(:strong?).and_return(true)
                flexmock(plan.task_relation_graph_for(Roby::TaskStructure::Dependency)).
                    should_receive(:strong?).and_return(true)
                root, task0, task1 = prepare_plan add: 3
                root.depends_on task0
                replace(task0, task1)
                assert root.depends_on?(task0)
                refute root.depends_on?(task1)
            end
        end

        def self.it_matches_common_replace_transaction_behaviour_for_handler(handler_type, &create_handler)
            it "does not wrap the target event if the source event does not have a copy_on_replace #{handler_type}" do
                task0, task1 = prepare_plan add: 2
                create_handler.call(task0.start_event, on_replace: :drop) { }
                plan.in_transaction do |trsc|
                    p_task0, p_task1 = trsc[task0], trsc[task1]
                    replace_op(p_task0, p_task1)
                    assert_equal [], p_task0.each_event.map(&:symbol)
                    assert_equal [], p_task1.each_event.map(&:symbol)
                    trsc.commit_transaction
                end
                assert_equal [], task1.start_event.send(handler_type).to_a
            end

            it "wraps the target event if the source event has a copy_on_replace #{handler_type} at the plan level" do
                task0, task1 = prepare_plan add: 2
                create_handler.call(task0.start_event, on_replace: :copy) { }
                plan.in_transaction do |trsc|
                    p_task0, p_task1 = trsc[task0], trsc[task1]
                    replace_op(p_task0, p_task1)
                    assert_equal [], p_task0.each_event.map(&:symbol)
                    assert_equal [:start], p_task1.each_event.map(&:symbol)
                    trsc.commit_transaction
                end
                assert_equal 1, task0.start_event.send(handler_type).size
                assert_equal task0.start_event.send(handler_type), task1.start_event.send(handler_type)
            end

            it "wraps the target event if the source event has a copy_on_replace #{handler_type} at the transaction level" do
                task0, task1 = prepare_plan add: 2
                
                plan.in_transaction do |trsc|
                    p_task0, p_task1 = trsc[task0], trsc[task1]
                    create_handler.call(p_task0.start_event, on_replace: :copy) { }
                    replace_op(p_task0, p_task1)
                    assert_equal [:start], p_task0.each_event.map(&:symbol)
                    assert_equal [:start], p_task1.each_event.map(&:symbol)
                    trsc.commit_transaction
                end
                assert_equal 1, task0.start_event.send(handler_type).size
                assert_equal task0.start_event.send(handler_type), task1.start_event.send(handler_type)
            end
        end

        def self.it_matches_common_replace_transaction_behaviour
            it_matches_common_replace_transaction_behaviour_for_handler(:finalization_handlers) do |event, args|
                event.when_finalized(args) {}
            end
            it_matches_common_replace_transaction_behaviour_for_handler(:handlers) do |event, args|
                event.on(args) {}
            end
            it_matches_common_replace_transaction_behaviour_for_handler(:unreachable_handlers) do |event, args|
                event.if_unreachable(args) {}
            end
            it "ignores task relations that are not part of the transaction" do
                root, task0, task1 = prepare_plan add: 3
                root.depends_on task0
                plan.in_transaction do |trsc|
                    trsc[task0].replace_by trsc[task1]
                    trsc.commit_transaction
                end
                assert root.depends_on?(task0)
                assert !root.depends_on?(task1)
            end
        end

        describe "#replace_subplan_by" do
            it_matches_common_replace_behaviour

            def replace(task0, task1)
                task0.replace_subplan_by(task1)
            end

            it "does not move relations between events in the task and its direct children" do
                task0, child, task1 = prepare_plan add: 3
                task0.depends_on child
                task0.start_event.signals child.start_event
                child.stop_event.forward_to task0.stop_event

                replace(task0, task1)
                assert_child_of task0.start_event, child.start_event, Roby::EventStructure::Signal
                assert_child_of child.stop_event, task0.stop_event, Roby::EventStructure::Forwarding
                refute_child_of task1.start_event, child.start_event, Roby::EventStructure::Signal
                refute_child_of child.stop_event, task1.stop_event, Roby::EventStructure::Forwarding
            end

            it "does not move relations between events in the task and the target's own events" do
                task0, task1 = prepare_plan add: 3
                task0.start_event.signals task1.start_event
                task1.stop_event.forward_to task0.stop_event

                replace(task0, task1)
                assert_child_of task0.start_event, task1.start_event, Roby::EventStructure::Signal
                assert_child_of task1.stop_event, task0.stop_event, Roby::EventStructure::Forwarding
            end

            it "does not move relations between events in the task and events in the target's direct children" do
                task0, child, task1 = prepare_plan add: 3
                task1.depends_on child
                task0.start_event.signals child.start_event
                child.stop_event.forward_to task0.stop_event

                replace(task0, task1)
                assert_child_of task0.start_event, child.start_event, Roby::EventStructure::Signal
                assert_child_of child.stop_event, task0.stop_event, Roby::EventStructure::Forwarding
                refute_child_of task1.start_event, child.start_event, Roby::EventStructure::Signal
                refute_child_of child.stop_event, task1.stop_event, Roby::EventStructure::Forwarding
            end

            it "moves relations between events in the task and events in its parents" do
                root, task0, task1 = prepare_plan add: 3
                root.depends_on task0
                root.start_event.signals task0.start_event
                task0.stop_event.forward_to root.stop_event

                replace(task0, task1)
                assert_child_of root.start_event, task1.start_event, Roby::EventStructure::Signal
                assert_child_of task1.stop_event, root.stop_event, Roby::EventStructure::Forwarding
                refute_child_of root.start_event, task0.start_event, Roby::EventStructure::Signal
                refute_child_of task0.stop_event, root.stop_event, Roby::EventStructure::Forwarding
            end

            it "moves relations between events in the task and events in its targets parents" do
                root, task0, task1 = prepare_plan add: 3
                root.depends_on task1
                root.start_event.signals task0.start_event
                task0.stop_event.forward_to root.stop_event

                replace(task0, task1)
                assert_child_of root.start_event, task1.start_event, Roby::EventStructure::Signal
                assert_child_of task1.stop_event, root.stop_event, Roby::EventStructure::Forwarding
                refute_child_of root.start_event, task0.start_event, Roby::EventStructure::Signal
                refute_child_of task0.stop_event, root.stop_event, Roby::EventStructure::Forwarding
            end

            describe "in a transaction" do
                def replace_op(task0, task1)
                    task0.replace_subplan_by(task1)
                end

                def replace(task0, task1)
                    plan.in_transaction do |trsc|
                        p_task0, p_task1 = trsc[task0], trsc[task1]
                        p_task0.replace_subplan_by p_task1
                        trsc.commit_transaction
                    end
                end

                it_matches_common_replace_transaction_behaviour

                it "does not wrap events that are not needed" do
                    task0, child, task1 = prepare_plan add: 3
                    task0.depends_on child
                    task0.start_event.signals child.start_event
                    child.stop_event.forward_to task0.stop_event
                    plan.in_transaction do |trsc|
                        trsc[child]
                        p_task0, p_task1 = trsc[task0], trsc[task1]
                        p_task0.replace_subplan_by(p_task1)
                        assert_equal [:start, :stop], p_task0.each_event.map(&:symbol)
                        assert_equal [:start, :stop], p_task1.each_event.map(&:symbol)
                    end
                end

                it "does not wrap events that are not needed" do
                    task0, task1 = prepare_plan add: 3
                    task0.start_event.signals task1.start_event
                    task1.stop_event.forward_to task0.stop_event
                    plan.in_transaction do |trsc|
                        p_task0, p_task1 = trsc[task0], trsc[task1]
                        p_task0.replace_subplan_by(p_task1)
                        assert_equal [:start, :stop], p_task0.each_event.map(&:symbol)
                        assert_equal [:start, :stop], p_task1.each_event.map(&:symbol)
                    end
                end

                it "does not wrap events that are not needed" do
                    task0, child, task1 = prepare_plan add: 3
                    task1.depends_on child
                    task0.start_event.signals child.start_event
                    child.stop_event.forward_to task0.stop_event
                    plan.in_transaction do |trsc|
                        trsc[child]
                        p_task0, p_task1 = trsc[task0], trsc[task1]
                        p_task0.replace_subplan_by(p_task1)
                        assert_equal [:start, :stop], p_task0.each_event.map(&:symbol)
                        assert_equal [:start, :stop], p_task1.each_event.map(&:symbol)
                    end
                end

                it "does not wrap events that are not needed" do
                    root, task0, task1 = prepare_plan add: 3
                    root.depends_on task0
                    root.start_event.signals task0.start_event
                    task0.stop_event.forward_to root.stop_event
                    plan.in_transaction do |trsc|
                        trsc[root]
                        p_task0, p_task1 = trsc[task0], trsc[task1]
                        p_task0.replace_subplan_by(p_task1)
                        assert_equal [:start, :stop], p_task0.each_event.map(&:symbol)
                        assert_equal [:start, :stop], p_task1.each_event.map(&:symbol)
                    end
                end

                it "does not wrap events that are not needed" do
                    root, task0, task1 = prepare_plan add: 3
                    root.depends_on task1
                    root.start_event.signals task0.start_event
                    task0.stop_event.forward_to root.stop_event
                    plan.in_transaction do |trsc|
                        trsc[root]
                        p_task0, p_task1 = trsc[task0], trsc[task1]
                        p_task0.replace_subplan_by(p_task1)
                        assert_equal [:start, :stop], p_task0.each_event.map(&:symbol)
                        assert_equal [:start, :stop], p_task1.each_event.map(&:symbol)
                    end
                end
            end
        end

        describe "#replace_by" do
            def replace(task0, task1)
                task0.replace_subplan_by(task1)
            end

            it "moves relations between events in the task and its direct children" do
                task0, child, task1 = prepare_plan add: 3
                task0.depends_on child
                task0.start_event.signals child.start_event
                child.stop_event.forward_to task0.stop_event

                task0.replace_by(task1)
                refute_child_of task0.start_event, child.start_event, Roby::EventStructure::Signal
                refute_child_of child.stop_event, task0.stop_event, Roby::EventStructure::Forwarding
                assert_child_of task1.start_event, child.start_event, Roby::EventStructure::Signal
                assert_child_of child.stop_event, task1.stop_event, Roby::EventStructure::Forwarding
            end

            it "does not move relations between events in the task and the target's own events" do
                task0, task1 = prepare_plan add: 3
                task0.start_event.signals task1.start_event
                task1.stop_event.forward_to task0.stop_event

                task0.replace_by(task1)
                assert_child_of task0.start_event, task1.start_event, Roby::EventStructure::Signal
                assert_child_of task1.stop_event, task0.stop_event, Roby::EventStructure::Forwarding
            end

            it "moves relations between events in the task and events in the target's direct children" do
                task0, child, task1 = prepare_plan add: 3
                task1.depends_on child
                task0.start_event.signals child.start_event
                child.stop_event.forward_to task0.stop_event

                task0.replace_by(task1)
                refute_child_of task0.start_event, child.start_event, Roby::EventStructure::Signal
                refute_child_of child.stop_event, task0.stop_event, Roby::EventStructure::Forwarding
                assert_child_of task1.start_event, child.start_event, Roby::EventStructure::Signal
                assert_child_of child.stop_event, task1.stop_event, Roby::EventStructure::Forwarding
            end

            it "moves relations between events in the task and events in its parents" do
                root, task0, task1 = prepare_plan add: 3
                root.depends_on task0
                root.start_event.signals task0.start_event
                task0.stop_event.forward_to root.stop_event

                task0.replace_by(task1)
                assert_child_of root.start_event, task1.start_event, Roby::EventStructure::Signal
                assert_child_of task1.stop_event, root.stop_event, Roby::EventStructure::Forwarding
                refute_child_of root.start_event, task0.start_event, Roby::EventStructure::Signal
                refute_child_of task0.stop_event, root.stop_event, Roby::EventStructure::Forwarding
            end

            it "moves relations between events in the task and events in its targets parents" do
                root, task0, task1 = prepare_plan add: 3
                root.depends_on task1
                root.start_event.signals task0.start_event
                task0.stop_event.forward_to root.stop_event

                task0.replace_by(task1)
                assert_child_of root.start_event, task1.start_event, Roby::EventStructure::Signal
                assert_child_of task1.stop_event, root.stop_event, Roby::EventStructure::Forwarding
                refute_child_of root.start_event, task0.start_event, Roby::EventStructure::Signal
                refute_child_of task0.stop_event, root.stop_event, Roby::EventStructure::Forwarding
            end

            describe "in a transaction" do
                def replace_op(task0, task1)
                    task0.replace_by(task1)
                end

                def replace(task0, task1)
                    plan.in_transaction do |trsc|
                        p_task0, p_task1 = trsc[task0], trsc[task1]
                        p_task0.replace_by p_task1
                        trsc.commit_transaction
                    end
                end

                it_matches_common_replace_transaction_behaviour

                it "imports events that have relations related to the replace" do
                    root, task0, task1 = prepare_plan add: 3
                    root.start_event.signals task0.start_event
                    plan.in_transaction do |trsc|
                        p_root, p_task0, p_task1 = trsc[root], trsc[task0], trsc[task1]
                        assert p_root.find_event(:start)
                        assert p_task0.find_event(:start)
                        assert_child_of p_root.start_event, p_task0.start_event, EventStructure::Signal
                        p_task0.replace_by p_task1
                        assert p_task1.find_event(:start)
                        refute_child_of p_root.start_event, p_task0.start_event, EventStructure::Signal
                        assert_child_of p_root.start_event, p_task1.start_event, EventStructure::Signal
                        trsc.commit_transaction
                    end
                    refute_child_of root.start_event, task0.start_event, EventStructure::Signal
                    assert_child_of root.start_event, task1.start_event, EventStructure::Signal
                end

                it "does not wrap events that are not needed" do
                    task0, child, task1 = prepare_plan add: 3
                    task0.depends_on child
                    task0.start_event.signals task1.start_event
                    task1.stop_event.forward_to task0.stop_event
                    plan.in_transaction do |trsc|
                        p_task0, p_task1 = trsc[task0], trsc[task1]
                        p_task0.replace_by(p_task1)
                        assert_equal [:start, :stop], p_task0.each_event.map(&:symbol)
                        assert_equal [:start, :stop], p_task1.each_event.map(&:symbol)
                    end
                end
            end
        end

        describe "#start_time" do
            subject { plan.add(t = Roby::Tasks::Simple.new); t }
            it "is nil on a pending task" do
                assert_equal nil, subject.start_time
            end
            it "is the time of the start event" do
                subject.start!
                assert_equal subject.start_event.last.time, subject.start_time
            end
        end

        describe "#end_time" do
            subject { plan.add(t = Roby::Tasks::Simple.new); t }
            it "is nil on a unfinished task" do
                subject.start!
                assert_equal nil, subject.end_time
            end
            it "is the time of the stop event" do
                subject.start!
                subject.stop!
                assert_equal subject.stop_event.last.time, subject.end_time
            end
        end

        describe "#lifetime" do
            subject { plan.add(t = Roby::Tasks::Simple.new); t }
            it "is nil on a pending task" do
                assert_equal nil, subject.lifetime
            end

            it "is the time between the start event and now on a running task" do
                subject.start!
                t = Time.now
                flexmock(Time).should_receive(:now).and_return(t)
                assert_equal t - subject.start_event.last.time, subject.lifetime
            end

            it "is the time between the stop and start events on a finished task" do
                subject.start!
                subject.stop!
                assert_equal subject.end_time - subject.start_time, subject.lifetime
            end
        end
    end
end

class TC_Task < Minitest::Test 
    def test_arguments_declaration
	model = Task.new_submodel { argument :from; argument :to }
	assert_equal([], Task.arguments.to_a)
	assert_equal([:from, :to].to_set, model.arguments.to_set)
    end

    def test_arguments_initialization
	model = Task.new_submodel { argument :arg; argument :to }
	plan.add(task = model.new(arg: 'B'))
	assert_equal({arg: 'B'}, task.arguments)
        assert_equal('B', task.arg)
        assert_equal(nil, task.to)
    end

    def test_arguments_initialization_uses_assignation_operator
	model = Task.new_submodel do
            argument :arg; argument :to

            undef_method :arg=
            def arg=(value)
                arguments[:assigned] = true
                arguments[:arg] = value
            end
        end

	plan.add(task = model.new(arg: 'B'))
	assert_equal({arg: 'B', assigned: true}, task.arguments)
    end

    def test_meaningful_arguments
	model = Task.new_submodel { argument :arg }
	plan.add(task = model.new(arg: 'B', useless: 'bla'))
	assert_equal({arg: 'B', useless: 'bla'}, task.arguments)
	assert_equal({arg: 'B'}, task.meaningful_arguments)
    end

    def test_meaningful_arguments_with_default_arguments
        child_model = Roby::Task.new_submodel do
            argument :start, default: 10
            argument :target
        end
        plan.add(child = child_model.new(target: 10))
        assert_equal({target: 10}, child.meaningful_arguments)
    end

    def test_arguments_partially_instanciated
	model = Task.new_submodel { argument :arg0; argument :arg1 }
	plan.add(task = model.new(arg0: 'B', useless: 'bla'))
	assert(task.partially_instanciated?)
        task.arg1 = 'C'
	assert(!task.partially_instanciated?)
    end

    def test_command_block
	FlexMock.use do |mock|
	    model = Tasks::Simple.new_submodel do 
		event :start do |context|
		    mock.start(self, context)
		    start_event.emit
		end
	    end
	    plan.add_mission_task(task = model.new)
	    mock.should_receive(:start).once.with(task, [42])
	    task.start!(42)
	end
    end

    def test_command_inheritance
        FlexMock.use do |mock|
            parent_m = Tasks::Simple.new_submodel do
                event :start do |context|
                    mock.parent_started(self, context)
                    start_event.emit
                end
            end

            child_m = parent_m.new_submodel do
                event :start do |context|
                    mock.child_started(self, context.first)
                    super(context.first / 2)
                end
            end

            plan.add_mission_task(task = child_m.new)
            mock.should_receive(:parent_started).once.with(task, 21)
            mock.should_receive(:child_started).once.with(task, 42)
            task.start!(42)
        end
    end

    def assert_task_relation_set(task, relation, expected)
        plan.add(task)
        task.each_event do |from|
            task.each_event do |to|
                next if from == to
                exp = expected[from.symbol]
                if exp == to.symbol || (exp.respond_to?(:include?) && exp.include?(to.symbol))
                    assert from.child_object?(to, relation), "expected relation #{from} => #{to} in #{relation} is missing"
                else
                    assert !from.child_object?(to, relation), "unexpected relation #{from} => #{to} found in #{relation}"
                end
            end
        end
    end

    def do_test_instantiate_model_relations(method, relation, additional_links = Hash.new)
	klass = Roby::Tasks::Simple.new_submodel do
            4.times { |i| event "e#{i + 1}", command: true }
            send(method, e1: [:e2, :e3], e4: :stop)
	end

        plan.add(task = klass.new)
        expected_links = Hash[e1: [:e2, :e3], e4: :stop]
        
        assert_task_relation_set task, relation, expected_links.merge(additional_links)
    end
    def test_instantiate_model_signals
        do_test_instantiate_model_relations(:signal, EventStructure::Signal, internal_error: :stop)
    end
    def test_instantiate_model_forward
        do_test_instantiate_model_relations(:forward, EventStructure::Forwarding,
                           success: :stop, aborted: :failed, failed: :stop)
    end
    def test_instantiate_model_causal_links
        do_test_instantiate_model_relations(:causal_link, EventStructure::CausalLink,
                           internal_error: :stop, success: :stop, aborted: :failed, failed: :stop)
    end

    
    def do_test_inherit_model_relations(method, relation, additional_links = Hash.new)
	base = Roby::Tasks::Simple.new_submodel do
            4.times { |i| event "e#{i + 1}", command: true }
            send(method, e1: [:e2, :e3])
	end
        subclass = base.new_submodel do
            send(method, e4: :stop)
        end

        task = base.new
        assert_task_relation_set task, relation,
            Hash[e1: [:e2, :e3]].merge(additional_links)

        task = subclass.new
        assert_task_relation_set task, relation,
            Hash[e1: [:e2, :e3], e4: :stop].merge(additional_links)
    end
    def test_inherit_model_signals
        do_test_inherit_model_relations(:signal, EventStructure::Signal, internal_error: :stop)
    end
    def test_inherit_model_forward
        do_test_inherit_model_relations(:forward, EventStructure::Forwarding,
                           success: :stop, aborted: :failed, failed: :stop)
    end
    def test_inherit_model_causal_links
        do_test_inherit_model_relations(:causal_link, EventStructure::CausalLink,
                           internal_error: :stop, success: :stop, aborted: :failed, failed: :stop)
    end

    # Test the behaviour of Task#on, and event propagation inside a task
    def test_instance_event_handlers
	plan.add(t1 = Tasks::Simple.new)
	plan.add(task = Tasks::Simple.new)
	FlexMock.use do |mock|
            task.start_event.on   { |event| mock.started(event.context) }
            task.start_event.on   { |event| task.success_event.emit(*event.context) }
            task.success_event.on { |event| mock.success(event.context) }
            task.stop_event.on    { |event| mock.stopped(event.context) }
	    mock.should_receive(:started).once.with([42]).ordered
	    mock.should_receive(:success).once.with([42]).ordered
	    mock.should_receive(:stopped).once.with([42]).ordered
	    task.start!(42)
	end
        assert(task.finished?)
	event_history = task.history.map { |ev| ev.generator }
	assert_equal([task.start_event, task.success_event, task.stop_event], event_history)
    end

    def test_instance_signals
	FlexMock.use do |mock|
	    t1, t2 = prepare_plan add: 3, model: Tasks::Simple
            t1.start_event.signals t2.start_event

            t2.start_event.on { |ev| mock.start }
            mock.should_receive(:start).once
	    t1.start!
	end
    end

    def test_instance_signals_plain_events
	t = prepare_plan missions: 1, model: Tasks::Simple
	e = EventGenerator.new(true)
        t.start_event.signals e
	t.start!
	assert(e.emitted?)
    end

    def test_model_forwardings
	model = Tasks::Simple.new_submodel do
	    forward start: :failed
	end
	assert_equal({ start: [:failed, :stop].to_set }, model.forwarding_sets)
	assert_equal({}, Tasks::Simple.signal_sets)

	assert_equal([:failed, :stop].to_set, model.forwardings(:start))
	assert_equal([:stop].to_set,          model.forwardings(:failed))
	assert_equal([:stop].to_set,          model.enum_for(:each_forwarding, :failed).to_set)

        plan.add(task = model.new)
        task.start!

	# Make sure the model-level relation is not applied to parent models
	plan.add(task = Tasks::Simple.new)
	task.start!
	assert(!task.failed?)
    end

    def test_model_event_handlers
	model = Tasks::Simple.new_submodel
        assert_raises(ArgumentError) { model.on(:start) { |a, b| } }

	FlexMock.use do |mock|
	    model.on :start do |ev|
		mock.start_called(self)
	    end
	    plan.add(task = model.new)
	    mock.should_receive(:start_called).with(task).once
	    task.start!

            # Make sure the model-level handler is not applied to parent models
            plan.add(task = Tasks::Simple.new)
            task.start!
            assert(!task.failed?)
	end
    end

    def test_instance_forward_to
	FlexMock.use do |mock|
	    t1, t2 = prepare_plan missions: 2, model: Tasks::Simple
            t1.start_event.forward_to t2.start_event
            t2.start_event.on { |context| mock.start }

	    mock.should_receive(:start).once
	    t1.start!
	end
    end

    def test_instance_forward_to_plain_events
	FlexMock.use do |mock|
	    t1 = prepare_plan missions: 1, model: Tasks::Simple
	    ev = EventGenerator.new do 
		mock.called
		ev.emit
	    end
	    ev.on { |event| mock.emitted }
            t1.start_event.forward_to ev

	    mock.should_receive(:called).never
	    mock.should_receive(:emitted).once
	    t1.start!
	end
    end

    def test_terminal_option
	klass = Task.new_submodel do
            event :terminal, terminal: true
        end
        assert klass.event_model(:terminal).terminal?
        plan.add(task = klass.new)
        assert task.event(:terminal).terminal?
        assert task.event(:terminal).child_object?(task.stop_event, EventStructure::Forwarding)
    end

    ASSERT_EVENT_ALL_PREDICATES = [:terminal?, :failure?, :success?]
    ASSERT_EVENT_PREDICATES = {
        normal:   [],
        stop:     [:terminal?],
        failed:   [:terminal?, :failure?],
        success:  [:terminal?, :success?]
    }

    def assert_model_event_flag(model, event_name, model_flag)
        if model_flag != :normal
            assert model.event_model(event_name).terminal?, "#{model}.#{event_name}.terminal? returned false"
        else
            assert !model.event_model(event_name).terminal?, "#{model}.#{event_name}.terminal? returned true"
        end
    end

    def assert_event_flag(task, event_name, instance_flag, model_flag)
        ASSERT_EVENT_PREDICATES[instance_flag].each do |pred|
            assert task.event(event_name).send(pred), "#{task}.#{event_name}.#{pred} returned false"
        end
        (ASSERT_EVENT_ALL_PREDICATES - ASSERT_EVENT_PREDICATES[instance_flag]).each do |pred|
            assert !task.event(event_name).send(pred), "#{task}.#{event_name}.#{pred} returned true"
        end
        assert_model_event_flag(task, event_name, model_flag)
    end

    def test_terminal_forward_stop(target_event = :stop)
	klass = Task.new_submodel do
	    event :direct
            event :indirect
            event :intermediate
	end
        plan.add(task = klass.new)
        task.direct_event.forward_to task.event(target_event)
        task.indirect_event.forward_to task.intermediate_event
        task.intermediate_event.forward_to task.event(target_event)
        assert_event_flag(task, :direct, target_event, :normal)
        assert_event_flag(task, :indirect, target_event, :normal)
    end
    def test_terminal_forward_success; test_terminal_forward_stop(:success) end
    def test_terminal_forward_failed; test_terminal_forward_stop(:failed) end

    def test_terminal_forward_stop_in_model(target_event = :stop)
	klass = Task.new_submodel do
	    event :direct
            forward direct: target_event

            event :indirect
            event :intermediate
            forward indirect: :intermediate
            forward intermediate: target_event
	end
        assert_model_event_flag(klass, :direct, target_event)
        assert_model_event_flag(klass, :indirect, target_event)
        plan.add(task = klass.new)
        assert_event_flag(task, :direct, target_event, target_event)
        assert_event_flag(task, :indirect, target_event, target_event)
    end
    def test_terminal_forward_success_in_model; test_terminal_forward_stop_in_model(:success) end
    def test_terminal_forward_failed_in_model; test_terminal_forward_stop_in_model(:failed) end

    def test_terminal_signal_stop(target_event = :stop)
	klass = Task.new_submodel do
	    event :direct

            event :indirect
            event :intermediate, controlable: true
            event target_event, controlable: true, terminal: true
	end
        plan.add(task = klass.new)
        task.direct_event.signals task.event(target_event)
        task.indirect_event.signals task.intermediate_event
        task.intermediate_event.signals task.event(target_event)
        assert_event_flag(task, :direct, target_event, :normal)
        assert_event_flag(task, :indirect, target_event, :normal)
    end
    def test_terminal_signal_success; test_terminal_signal_stop(:success) end
    def test_terminal_signal_failed; test_terminal_signal_stop(:failed) end

    def test_terminal_signal_stop_in_model(target_event = :stop)
	klass = Task.new_submodel do
	    event :direct

            event :indirect
            event :intermediate, controlable: true
            event target_event, controlable: true, terminal: true

            signal direct: target_event
            signal indirect: :intermediate
            signal intermediate: target_event
	end
        assert_model_event_flag(klass, :direct, target_event)
        assert_model_event_flag(klass, :indirect, target_event)
        plan.add(task = klass.new)
        assert_event_flag(task, :direct, target_event, target_event)
        assert_event_flag(task, :indirect, target_event, target_event)
    end
    def test_terminal_signal_success_in_model; test_terminal_signal_stop_in_model(:success) end
    def test_terminal_signal_failed_in_model; test_terminal_signal_stop_in_model(:failed) end

    def test_terminal_alternate_stop(target_event = :stop)
	klass = Task.new_submodel do
            event :forward_first
            event :intermediate_signal
            event target_event, controlable: true, terminal: true

            event :signal_first
            event :intermediate_forward, controlable: true
	end
        assert_model_event_flag(klass, :signal_first, :normal)
        assert_model_event_flag(klass, :forward_first, :normal)
        plan.add(task = klass.new)

        task.forward_first_event.forward_to task.event(:intermediate_signal)
        task.intermediate_signal_event.signals task.event(target_event)
        task.signal_first_event.signals task.event(:intermediate_forward)
        task.intermediate_forward_event.forward_to task.event(target_event)
        assert_event_flag(task, :signal_first, target_event, :normal)
        assert_event_flag(task, :forward_first, target_event, :normal)
    end
    def test_terminal_alternate_success; test_terminal_signal_stop(:success) end
    def test_terminal_alternate_failed; test_terminal_signal_stop(:failed) end

    def test_terminal_alternate_stop_in_model(target_event = :stop)
	klass = Task.new_submodel do
            event :forward_first
            event :intermediate_signal
            event target_event, controlable: true, terminal: true

            event :signal_first
            event :intermediate_forward, controlable: true

            forward forward_first: :intermediate_signal
            signal  intermediate_signal: target_event
            signal signal_first: :intermediate_forward
            forward intermediate_forward: target_event
	end
        assert_model_event_flag(klass, :signal_first, target_event)
        assert_model_event_flag(klass, :forward_first, target_event)
        plan.add(task = klass.new)
        assert_event_flag(task, :signal_first, target_event, target_event)
        assert_event_flag(task, :forward_first, target_event, target_event)
    end
    def test_terminal_alternate_success_in_model; test_terminal_signal_stop_in_model(:success) end
    def test_terminal_alternate_failed_in_model; test_terminal_signal_stop_in_model(:failed) end

    def test_should_not_establish_signal_from_terminal_to_non_terminal
	klass = Task.new_submodel do
	    event :terminal, terminal: true
            event :intermediate
	end
        assert_raises(ArgumentError) { klass.forward terminal: :intermediate }
        klass.new
    end

    # Tests Task::event
    def test_event_declaration
	klass = Task.new_submodel do
	    def ev_not_controlable;     end
	    def ev_method(event = :ev_method); :ev_method if event == :ev_redirected end

	    event :ev_contingent
	    event :ev_controlable do |*events|
                :ev_controlable
            end

	    event :ev_not_controlable
	    event :ev_redirected, command: lambda { |task, event, *args| task.ev_method(event) }
	end

	klass.event :ev_terminal, terminal: true, command: true

	plan.add(task = klass.new)
	assert_respond_to(task, :start!)
        assert_respond_to(task, :start?)

        # Test modifications to the class hierarchy
        my_event = nil
        my_event = klass.const_get(:EvContingent)
        assert_raises(NameError) { klass.superclass.const_get(:EvContingent) }
        assert_equal( TaskEvent, my_event.superclass )
        assert_equal( :ev_contingent, my_event.symbol )
        assert( klass.has_event?(:ev_contingent) )
    
        my_event = klass.const_get(:EvTerminal)
        assert_equal( :ev_terminal, my_event.symbol )

        # Check properties on EvContingent
        assert( !klass::EvContingent.respond_to?(:call) )
        assert( !klass::EvContingent.controlable? )
        assert( !klass::EvContingent.terminal? )

        # Check properties on EvControlable
        assert( klass::EvControlable.controlable? )
        assert( klass::EvControlable.respond_to?(:call) )
        event = klass::EvControlable.new(task, task.ev_controlable_event, 0, nil)
        assert_equal(:ev_controlable, klass::EvControlable.call(task, :ev_controlable))

        # Check Event.terminal? if terminal: true
        assert( klass::EvTerminal.terminal? )

        # Check controlable: [proc] behaviour
        assert( klass::EvRedirected.controlable? )
        
        # Check that command: false disables controlable?
        assert( !klass::EvNotControlable.controlable? )

        # Check validation of options[:command]
        assert_raises(ArgumentError) { klass.event :try_event, command: "bla" }

        plan.add(task = EmptyTask.new)
	start_event = task.start_event

        assert_equal(start_event, task.start_event)
        assert_equal([], start_event.handlers)
	# Note that the start => stop forwarding is added because 'start' is
	# detected as terminal in the EmptyTask model
        assert_equal([task.stop_event, task.success_event].to_set, start_event.enum_for(:each_forwarding).to_set)
        start_model = task.event_model(:start)
        assert_equal(start_model, start_event.event_model)
        assert_equal([:stop, :success].to_set, task.model.enum_for(:each_forwarding, :start).to_set)
    end
    def test_status
	task = Roby::Task.new_submodel do
	    event :start do |context|
	    end
	    event :failed, terminal: true do |context|
	    end
	    event :stop do |context|
		failed!
	    end
	end.new
	plan.add(task)

	assert(task.pending?)
	assert(!task.starting?)
	assert(!task.running?)
	assert(!task.success?)
	assert(!task.failed?)
	assert(!task.finishing?)
	assert(!task.finished?)

	task.start!
	assert(!task.pending?)
	assert(task.starting?)
	assert(!task.running?)
	assert(!task.success?)
	assert(!task.failed?)
	assert(!task.finishing?)
	assert(!task.finished?)

	task.start_event.emit
	assert(!task.pending?)
	assert(!task.starting?)
	assert(task.running?)
	assert(!task.success?)
	assert(!task.failed?)
	assert(!task.finishing?)
	assert(!task.finished?)

	task.stop!
	assert(!task.pending?)
	assert(!task.starting?)
	assert(task.running?)
	assert(!task.success?)
	assert(!task.failed?)
	assert(task.finishing?)
	assert(!task.finished?)

	task.failed_event.emit
	assert(!task.pending?)
	assert(!task.starting?)
	assert(!task.running?)
	assert(!task.success?)
	assert(task.failed?)
	assert(!task.finishing?)
	assert(task.finished?)
    end

    def test_status_precisely
        status_flags = [:pending?, :starting?, :started?, :running?, :finishing?, :finished?, :success?]
        expected_status = lambda do |true_flags|
            result = true_flags.dup
            status_flags.each do |fl|
                if !true_flags.has_key?(fl)
                    result[fl] = false
                end
            end
            result
        end

        mock = flexmock
	task = Roby::Task.new_submodel do
            define_method(:complete_status) do
                as_array = status_flags.map { |s| [s, send(s)] }
                Hash[as_array]
            end

	    event :start do |context|
                mock.cmd_start(complete_status)
                start_event.emit
	    end
            on :start do |context|
                mock.on_start(complete_status)
            end
	    event :failed, terminal: true do |context|
                mock.cmd_failed(complete_status)
                failed_event.emit
	    end
            on :failed do |ev|
                mock.on_failed(complete_status)
            end
	    event :stop do |context|
                mock.cmd_stop(complete_status)
                failed!
	    end
            on :stop do |context|
                mock.on_stop(complete_status)
            end
	end.new
        plan.add(task)
        task.stop_event.when_unreachable do
            mock.stop_unreachable
        end

        mock.should_expect do |m|
            m.cmd_start(expected_status[:starting? => true, :success? => nil]).once.ordered
            m.on_start(expected_status[:started? => true, :running? => true, :success? => nil]).once.ordered
            m.cmd_stop(expected_status[:started? => true, :running? => true, :success? => nil]).once.ordered
            m.cmd_failed(expected_status[:started? => true, :running? => true, :finishing? => true, :success? => nil]).once.ordered
            m.on_failed(expected_status[:started? => true, :running? => true, :finishing? => true, :success? => false]).once.ordered
            m.on_stop(expected_status[:started? => true, :finished? => true, :success? => false]).once.ordered
            m.stop_unreachable.once.ordered
        end

        assert(task.pending?)
        task.start!
        task.stop!
    end

    def test_context_propagation
	FlexMock.use do |mock|
	    model = Tasks::Simple.new_submodel do
		event :start do |context|
		    mock.starting(context)
		    start_event.emit(*context)
		end
		on(:start) do |event| 
		    mock.started(event.context)
		end


		event :pass_through, command: true
		on(:pass_through) do |event|
		    mock.pass_through(event.context)
		end

		on(:stop)  { |event| mock.stopped(event.context) }
	    end
	    plan.add_mission_task(task = model.new)

	    mock.should_receive(:starting).with([42]).once
	    mock.should_receive(:started).with([42]).once
	    mock.should_receive(:pass_through).with([10]).once
	    mock.should_receive(:stopped).with([21]).once
	    task.start!(42)
	    task.pass_through!(10)
            task.stop_event.emit(21)
	    assert(task.finished?)
	end
    end

    def test_inheritance_overloading
        base = Roby::Task.new_submodel
        base.event :ctrl, command: true
        base.event :stop
        assert(!base.find_event_model(:stop).controlable?)

        sub = base.new_submodel
        sub.event :start, command: true
        assert_raises(ArgumentError) { sub.event :ctrl, command: false }
        assert_raises(ArgumentError) { sub.event :failed, terminal: false }
        assert_raises(ArgumentError) { sub.event :failed }

        sub.event(:stop) { |context| }
        assert(sub.find_event_model(:stop).controlable?)

	sub = base.new_submodel
        sub.start_event { |context| }
    end

    def test_singleton
	model = Task.new_submodel do
	    def initialize
		singleton_class.event(:start, command: true)
		singleton_class.stop_event
		super
	    end
	    event :inter
	end

	ev_models = Hash[*model.enum_for(:each_event).to_a.flatten]
	assert_equal([:start, :success, :aborted, :internal_error, :updated_data, :stop, :failed, :inter, :poll_transition].to_set, ev_models.keys.to_set)

	plan.add(task = model.new)
	ev_models = Hash[*task.model.enum_for(:each_event).to_a.flatten]
	assert_equal([:start, :success, :aborted, :internal_error, :updated_data, :stop, :failed, :inter, :poll_transition].to_set, ev_models.keys.to_set)
	assert( ev_models[:start].symbol )
	assert( ev_models[:start].name || ev_models[:start].name.length > 0 )
    end

    describe "event validation" do
        attr_reader :task
        before do
            model = Tasks::Simple.new_submodel do
                event(:inter, command: true)
            end
            plan.add(@task = model.new)
            plan.execution_engine.display_exceptions = false
        end

        after do
            plan.execution_engine.display_exceptions = true
        end

        describe "a pending task" do
            it "raises if calling an intermediate event" do
                assert_raises(CommandFailed) { task.inter! }
                assert(!task.inter_event.pending)
            end
            it "raises if emitting an intermediate event" do
                inhibit_fatal_messages do
                    assert_raises(EmissionFailed) { task.inter_event.emit }
                end
                assert(!task.inter_event.pending)
            end
        end

        describe "a running task" do
            before do
                task.start!
            end
            it "raises if calling the start event" do
                assert_raises(CommandFailed) { task.start! }
            end
        end
        describe "a finished task" do
            before do
                task.start!
                task.inter!
                task.stop!
            end
            it "raises if calling an intermediate event" do
                assert_raises(CommandFailed) { task.inter! }
            end
            it "raises if emitting an intermedikate event" do
                assert_raises(TaskEventNotExecutable) { task.inter_event.emit }
            end
        end

        it "correctly handles unordered emissions during the propagation phase" do
            model = Tasks::Simple.new_submodel do
                event :start do |context|
                    inter_event.emit
                    start_event.emit
                end

                event :inter do |context|
                    inter_event.emit
                end
            end
            plan.add(task = model.new)
            task.start!
            assert task.inter_event.emitted?
        end
    end

    def test_finished
	model = Roby::Task.new_submodel do
	    event :start, command: true
	    event :failed, command: true, terminal: true
	    event :success, command: true, terminal: true
	    event :stop, command: true
	end

	plan.add(task = model.new)
	task.start!
	task.stop_event.emit
	assert(!task.success?)
	assert(!task.failed?)
	assert(task.finished?)
	assert_equal(task.stop_event.last, task.terminal_event)

	plan.add(task = model.new)
	task.start!
	task.success_event.emit
	assert(task.success?)
	assert(!task.failed?)
	assert(task.finished?)
	assert_equal(task.success_event.last, task.terminal_event)

	plan.add(task = model.new)
	task.start!
	task.failed_event.emit
	assert(!task.success?)
	assert(task.failed?)
	assert(task.finished?)
	assert_equal(task.failed_event.last, task.terminal_event)
    end

    def assert_exception_message(klass, msg)
        yield
        flunk 'no exception raised'
    rescue klass => e
        unless msg === e.message
            flunk "exception message '#{e.message}' does not match the expected pattern #{msg}"
        end
    rescue Exception => e
        flunk "expected an exception of class #{klass} but got #{e.full_message}"
    end

    def test_cannot_start_if_not_executable
        Roby.logger.level = Logger::FATAL
	model = Tasks::Simple.new_submodel do 
	    event(:inter, command: true)
            def executable?; false end
	end

        plan.add(task = model.new)
        assert_raises(TaskEventNotExecutable) { task.start_event.call }

        plan.add(task = model.new)
        assert_raises(TaskEventNotExecutable) { task.start! }
    end

    def test_cannot_leave_pending_if_not_executable
        Roby.logger.level = Logger::FATAL
        model = Tasks::Simple.new_submodel do
            def executable?; !pending?  end
        end
	plan.add(task = model.new)
        assert_raises(TaskEventNotExecutable) { task.start! }
    end

    def test_executable
	model = Tasks::Simple.new_submodel do 
	    event(:inter, command: true)
	end
	task = model.new

	assert(!task.executable?)
	assert(!task.start_event.executable?)
        task.executable = true
	assert(task.executable?)
	assert(task.start_event.executable?)
        task.executable = nil
	assert(!task.executable?)
	assert(!task.start_event.executable?)

	plan.add(task)
	assert(task.executable?)
	assert(task.start_event.executable?)
        task.executable = false
	assert(!task.executable?)
	assert(!task.start_event.executable?)
        task.executable = nil
	assert(task.executable?)
	assert(task.start_event.executable?)

	# Cannot change the flag if the task is running
        task.executable = nil
        task.start!
	assert_raises(ModelViolation) { task.executable = false }
    end
	
    class ParameterizedTask < Roby::Task
        argument :arg
    end
    
    class AbstractTask < Roby::Task
        abstract
    end

    class NotExecutablePlan < Roby::Plan
        def executable?
            false
	end
    end
    
    def exception_propagator(task, relation)
	first_task  = Tasks::Simple.new
	second_task = task
	first_task.send(relation, :start, second_task, :start)
	first_task.start!
    end
    
    def assert_direct_call_validity_check(substring, check_signaling)
        with_log_level(Roby, Logger::FATAL) do
            error = yield
            assert_exception_message(TaskEventNotExecutable, substring) { error.start! }
            error = yield
            assert_exception_message(TaskEventNotExecutable, substring) {error.start_event.call(nil)}
            error = yield
            assert_exception_message(TaskEventNotExecutable, substring) {error.start_event.emit(nil)}
            
            if check_signaling then
                error = yield
                assert_exception_message(TaskEventNotExecutable, substring) do
                   exception_propagator(error, :signals)
                end
                error = yield
                assert_exception_message(TaskEventNotExecutable, substring) do
                   exception_propagator(error, :forward_to)
                end
            end
        end
    end

    def assert_failure_reason(task, exception, message = nil)
        if block_given?
            begin
                yield
            rescue exception
            end
        end

        assert(task.failed?, "#{task} did not fail")
        assert_kind_of(exception, task.failure_reason, "wrong error type for #{task}: expected #{exception}, got #{task.failure_reason}")
        assert(task.failure_reason.message =~ message, "error message '#{task.failure_reason.message}' was expected to match #{message}") if message
    end
    
    def assert_emission_fails(message_match, check_signaling)
        error = yield
	assert_failure_reason(error, TaskEventNotExecutable, message_match) do
            error.start!
        end
        error = yield
	assert_failure_reason(error, TaskEventNotExecutable, message_match) do
            error.start_event.call(nil)
        end

        error = yield
        assert_exception_message(TaskEventNotExecutable, message_match) do
            error.start_event.emit(nil)
        end
	
	if check_signaling then
	    error = yield
	    assert_exception_message(TaskEventNotExecutable, message_match) do
                exception_propagator(error, :forward_to)
            end

	    error = yield
            exception_propagator(error, :signals)
	    assert_failure_reason(error, TaskEventNotExecutable, message_match)
	end
    end
        
    def test_exception_refinement
        # test for a task that is in no plan
        assert_direct_call_validity_check(/plan is not executable/,false) do
            Tasks::Simple.new
	end

	# test for a not executable plan
	erroneous_plan = NotExecutablePlan.new	
	assert_direct_call_validity_check(/plan is not executable/,false) do
	   erroneous_plan.add(task = Tasks::Simple.new)
	   task
	end
        erroneous_plan.clear

        # test for a not executable task
        assert_direct_call_validity_check(/is not executable/,true) do
            plan.add(task = Tasks::Simple.new)
            task.executable = false
            task
	end
        
	# test for partially instanciation
	assert_direct_call_validity_check(/partially instanciated/,true) do
	   plan.add(task = ParameterizedTask.new)
	   task
	end

        # test for an abstract task
        assert_direct_call_validity_check(/abstract/,true) do
            plan.add(task = AbstractTask.new)
            task
	end
    end
	
    

    def test_task_success_failure
	FlexMock.use do |mock|
	    plan.add_mission_task(t = EmptyTask.new)
	    [:start, :success, :stop].each do |name|
                t.event(name).on { |event| mock.send(name) }
		mock.should_receive(name).once.ordered
	    end
	    t.start!
	end
    end

    def aggregator_test(a, *tasks)
	plan.add_mission_task(a)
	FlexMock.use do |mock|
	    [:start, :success, :stop].each do |name|
                a.event(name).on { |ev| mock.send(name) }
		mock.should_receive(name).once.ordered
	    end
	    a.start!
	    assert( tasks.all? { |t| t.finished? })
	end
    end

    def test_task_parallel_aggregator
        t1, t2 = EmptyTask.new, EmptyTask.new
	plan.add([t1, t2])
	aggregator_test((t1 | t2), t1, t2)
        t1, t2 = EmptyTask.new, EmptyTask.new
	plan.add([t1, t2])
	aggregator_test( (t1 | t2).to_task, t1, t2 )
    end

    def task_tuple(count)
	tasks = (1..count).map do 
	    t = EmptyTask.new
	    t.executable = true
	    t
	end
	yield(tasks)
    end

    def test_sequence
	task_tuple(2) { |t1, t2| aggregator_test( (t1 + t2), t1, t2 ) }
        task_tuple(2) do |t1, t2| 
	    s = t1 + t2
	    aggregator_test( s.to_task, t1, t2 )
	    assert(! t1.stop_event.related_object?(s.stop_event, EventStructure::Precedence))
	end

	task_tuple(3) do |t1, t2, t3|
	    s = t2 + t3
	    s.unshift t1
	    aggregator_test(s, t1, t2, t3)
	end
	
	task_tuple(3) do |t1, t2, t3|
	    s = t2 + t3
	    s.unshift t1
	    aggregator_test(s.to_task, t1, t2, t3)
	end
    end
    def test_sequence_child_of
	model = Tasks::Simple.new_submodel
	t1, t2 = prepare_plan tasks: 2, model: Tasks::Simple

	seq = (t1 + t2)
	assert(seq.child_object?(t1, TaskStructure::Dependency))
	assert(seq.child_object?(t2, TaskStructure::Dependency))

	task = seq.child_of(model)
        assert !seq.plan

	plan.add_mission_task(task)

	task.start!
	assert(t1.running?)
	t1.success!
	assert(t2.running?)
	t2.success!
	assert(task.success?)
    end

    def test_compatible_state
	t1, t2 = prepare_plan add: 2, model: Tasks::Simple

	assert(t1.compatible_state?(t2))
	t1.start!; assert(! t1.compatible_state?(t2) && !t2.compatible_state?(t1))
	t1.stop!; assert(t1.compatible_state?(t2) && t2.compatible_state?(t1))

	plan.add(t1 = Tasks::Simple.new)
	t1.start!
	t2.start!; assert(t1.compatible_state?(t2) && t2.compatible_state?(t1))
	t1.stop!; assert(t1.compatible_state?(t2) && !t2.compatible_state?(t1))
    end

    def test_fullfills
	abstract_task_model = TaskService.new_submodel do
	    argument :abstract
	end
	task_model = Task.new_submodel do
	    include abstract_task_model
	    argument :index; argument :universe
	end

	t1, t2 = task_model.new, task_model.new
	plan.add([t1, t2])
	assert(t1.fullfills?(t1.model))
	assert(t1.fullfills?(t2))
	assert(t1.fullfills?(abstract_task_model))
	
	plan.add(t2 = task_model.new(index: 2))
	assert(!t1.fullfills?(t2))

	plan.add(t3 = task_model.new(universe: 42))
	assert(t3.fullfills?(t1))
	assert(!t1.fullfills?(t3))
	plan.add(t3 = task_model.new(universe: 42, index: 21))
	assert(t3.fullfills?(task_model, universe: 42))

	plan.add(t3 = Task.new_submodel.new)
	assert(!t1.fullfills?(t3))

	plan.add(t3 = task_model.new_submodel.new)
	assert(!t1.fullfills?(t3))
	assert(t3.fullfills?(t1))
    end

    def test_fullfill_using_explicit_fullfilled_model_on_task_model
        tag = TaskService.new_submodel
        proxy_model = Task.new_submodel do
            include tag
        end
        proxy_model.fullfilled_model = [tag]
        real_model = Task.new_submodel do
            include tag
        end

        t1, t2  = real_model.new, proxy_model.new
        assert(t1.fullfills?(t2))
        assert(t1.fullfills?([t2]))
        assert(t1.fullfills?(tag))
    end

    def test_related_tasks
	t1, t2, t3 = (1..3).map { Tasks::Simple.new }.
	    each { |t| plan.add(t) }
	t1.depends_on t2
	t1.start_event.signals t3.start_event
	assert_equal([t3].to_set, t1.start_event.related_tasks)
	assert_equal([t2].to_set, t1.related_objects)
	assert_equal([t2, t3].to_set, t1.related_tasks)
    end

    def test_related_events
	t1, t2, t3 = (1..3).map { Tasks::Simple.new }.
	    each { |t| plan.add(t) }
	t1.depends_on t2
	t1.start_event.signals t3.start_event
	assert_equal([t3.start_event].to_set, t1.related_events)
    end

    def test_if_unreachable
	model = Tasks::Simple.new_submodel do
	    event :ready
	end

	# Test that the stop event will make the handler called on a running task
	FlexMock.use do |mock|
	    plan.add(task = model.new)
	    ev = task.success_event
	    ev.if_unreachable(cancel_at_emission: false) { mock.success_called }
	    ev.if_unreachable(cancel_at_emission: true)  { mock.success_cancel_called }
	    mock.should_receive(:success_called).once
	    mock.should_receive(:success_cancel_called).never
	    ev = task.ready_event
	    ev.if_unreachable(cancel_at_emission: false) { mock.ready_called }
	    ev.if_unreachable(cancel_at_emission: true)  { mock.ready_cancel_called }
	    mock.should_receive(:ready_called).once
	    mock.should_receive(:ready_cancel_called).once

	    task.start!
	    task.success!
	end
	execution_engine.garbage_collect

	# Test that it works on pending tasks too
	FlexMock.use do |mock|
	    plan.add(task = model.new)
	    ev = task.success_event
	    ev.if_unreachable(cancel_at_emission: false) { mock.success_called }
	    ev.if_unreachable(cancel_at_emission: true)  { mock.success_cancel_called }
	    mock.should_receive(:success_called).once
	    mock.should_receive(:success_cancel_called).once

	    ev = task.ready_event
	    ev.if_unreachable(cancel_at_emission: false) { mock.ready_called }
	    ev.if_unreachable(cancel_at_emission: true)  { mock.ready_cancel_called }
	    mock.should_receive(:ready_called).once
	    mock.should_receive(:ready_cancel_called).once

	    execution_engine.garbage_collect
	end

    end

    def test_stop_becomes_unreachable
	FlexMock.use do |mock|
	    plan.add(task = Roby::Tasks::Simple.new)
            ev = task.stop_event
	    ev.if_unreachable(cancel_at_emission: false) { mock.stop_called }
	    ev.if_unreachable(cancel_at_emission: true)  { mock.stop_cancel_called }

            mock.should_receive(:stop_called).once
            mock.should_receive(:stop_cancel_called).never
            task.start!
            task.stop!
        end
    end

    def test_achieve_with
	slave  = Tasks::Simple.new
	master = Task.new_submodel do
	    terminates
	    event :start do |context|
		start_event.achieve_with slave
	    end
	end.new
	plan.add([master, slave])

	master.start!
	assert(master.starting?)
	assert(master.depends_on?(slave))
	slave.start!
	slave.success!
	assert(master.started?)
    end

    def test_achieve_with_fails_emission_if_child_success_becomes_unreachable
	slave  = Tasks::Simple.new
	master = Task.new_submodel do
	    event :start do |context|
		start_event.achieve_with slave.start_event
	    end
	end.new
	plan.add([master, slave])

	master.start!
	assert(master.starting?)
	plan.remove_task(slave)
        assert master.failed?
        assert_kind_of EmissionFailed, master.failure_reason
        assert_kind_of UnreachableEvent, master.failure_reason.error
    end

    def test_task_group
	t1, t2 = Tasks::Simple.new, Tasks::Simple.new
	plan.add(g = Tasks::Group.new(t1, t2))

	g.start!
	assert(t1.running?)
	assert(t2.running?)

	t1.success!
	assert(g.running?)
	t2.success!
	assert(g.success?)
    end

    def test_poll_is_called_in_the_same_cycle_as_the_start_event
        mock = flexmock

        poll_cycles = []
        model = Tasks::Simple.new_submodel do
            poll { poll_cycles << plan.execution_engine.propagation_id }
        end
        t = prepare_plan permanent: 1, model: model
        t.poll { |task| poll_cycles << task.plan.execution_engine.propagation_id }
        t.start!
        expected = t.start_event.history.first.propagation_id
        assert_equal [expected, expected], poll_cycles
    end

    def test_poll_is_called_after_the_start_handlers
        mock = flexmock

        poll_cycles = []
        model = Tasks::Simple.new_submodel do
            on(:start) { |ev| mock.start_handler }
            poll { mock.poll_handler }
        end
        t = prepare_plan permanent: 1, model: model
        t.start_event.on { |ev| mock.start_handler }
        t.poll { |task| mock.poll_handler }
        mock.should_receive(:start_handler).ordered
        mock.should_receive(:poll_handler).ordered
        t.start!
    end

    def test_poll_on_pending_tasks
        mock = flexmock

        model = Tasks::Simple.new_submodel do
            poll do
                mock.polled_from_model(running?, self)
            end
        end
        t = prepare_plan permanent: 1, model: model
        t.poll do |task|
            mock.polled_from_instance(t.running?, task)
        end
        mock.should_receive(:polled_from_model).once.with(true, t)
        mock.should_receive(:polled_from_instance).once.with(true, t)

        t.start!

        # Verify that the poll block gets deregistered when  the task is
        # finished
        plan.unmark_permanent_task(t)
        t.stop!
        process_events
    end

    def test_poll_should_be_called_at_least_once
        mock = flexmock
        model = Tasks::Simple.new_submodel do
            on :start do |event|
                stop!
            end

            poll do
                mock.polled_from_model(running?, self)
            end
        end
        t = prepare_plan add: 1, model: model
        t.poll do |task|
            mock.polled_from_instance(t.running?, task)
        end
        mock.should_receive(:polled_from_model).once.with(true, t)
        mock.should_receive(:polled_from_instance).once.with(true, t)

        t.start!
        process_events
    end

    def test_poll_handler_on_running_task
        mock = flexmock
        t = prepare_plan permanent: 1, model: Roby::Tasks::Simple
        mock.should_receive(:polled_from_instance).at_least.once.with(true, t)

        t.start!
        t.poll do |task|
            mock.polled_from_instance(t.running?, task)
        end

        process_events

        # Verify that the poll block gets deregistered when  the task is
        # finished
        plan.unmark_permanent_task(t)
        t.stop!
        process_events
    end

    def test_error_in_polling
        Roby.logger.level = Logger::FATAL
        Roby::ExecutionEngine.logger.level = Logger::FATAL
	FlexMock.use do |mock|
	    mock.should_receive(:polled).once
	    klass = Tasks::Simple.new_submodel do
		poll do
		    mock.polled(self)
		    raise ArgumentError
		end
	    end

            plan.add_permanent_task(t = klass.new)
            assert_event_emission(t.internal_error_event) do
                t.start!
            end
            assert(t.stop?)
	end
    end

    def test_error_in_polling_with_delayed_stop
        Roby.logger.level = Logger::FATAL
        t = nil
	FlexMock.use do |mock|
	    mock.should_receive(:polled).once
	    klass = Tasks::Simple.new_submodel do
		poll do
		    mock.polled(self)
		    raise ArgumentError
		end

                event :stop do |ev|
                end
	    end

            plan.add_permanent_task(t = klass.new)
            assert_event_emission(t.internal_error_event) do
                t.start!
            end
            assert(t.failed?)
            assert(t.running?)
            assert(t.finishing?)
            t.stop_event.emit
            assert(t.failed?)
            assert(!t.running?)
            assert(t.finished?)
	end

    ensure
        if t.running?
            t.stop_event.emit
        end
    end

    def test_events_emitted_multiple_times
        # We generate an error, avoid having a spurious "non-fatal error"
        # message
        Roby::ExecutionEngine.make_own_logger(nil, Logger::FATAL)

	FlexMock.use do |mock|
	    mock.should_receive(:polled).once
	    mock.should_receive(:emitted).once
	    klass = Tasks::Simple.new_submodel do
		poll do
		    mock.polled(self)
                    internal_error_event.emit
                    internal_error_event.emit
		end
                on :internal_error do |ev|
                    mock.emitted
                end
	    end

            plan.add_permanent_task(t = klass.new)
            assert_event_emission(t.stop_event) do
                t.start!
            end
	end
    end

    def test_event_task_sources
	task = Tasks::Simple.new_submodel do
	    event :specialized_failure, command: true
	    forward specialized_failure: :failed
	end.new
	plan.add(task)

	task.start!
	assert_equal([], task.start_event.last.task_sources.to_a)

	ev = EventGenerator.new(true)
	ev.forward_to task.specialized_failure_event
	ev.call
	assert_equal([task.failed_event.last], task.stop_event.last.task_sources.to_a)
	assert_equal([task.specialized_failure_event.last, task.failed_event.last].to_set, task.stop_event.last.all_task_sources.to_set)
    end

    def test_dup
        model = Roby::Tasks::Simple.new_submodel do
            event :intermediate
        end
	plan.add(task = model.new)
	task.start!
        task.intermediate_event.emit

	new = task.dup
        assert !new.find_event(:stop)

	assert(!plan.has_task?(new))

	assert_kind_of(Roby::TaskArguments, new.arguments)
	assert_equal(task.arguments.to_hash, new.arguments.to_hash)

        assert(task.running?)
        assert(new.running?)
    end

    def test_failed_to_start
	plan.add(task = Roby::Test::Tasks::Simple.new)
        begin
            task.start_event.emit_failed
        rescue Exception
        end
        assert task.failed_to_start?
        assert_kind_of EmissionFailed, task.failure_reason
        assert task.failed?
        assert !task.pending?
        assert !task.running?
        assert_equal [], plan.find_tasks.pending.to_a
        assert_equal [], plan.find_tasks.running.to_a
        assert_equal [task], plan.find_tasks.failed.to_a
    end

    def test_cannot_call_event_on_task_that_failed_to_start
	plan.add(task = Roby::Test::Tasks::Simple.new)
        begin
            task.start_event.emit_failed
        rescue Exception
        end
        assert task.failed_to_start?
        assert_raises(Roby::CommandFailed) { task.stop! }
    end

    def test_cannot_call_event_on_task_that_finished
	plan.add(task = Roby::Test::Tasks::Simple.new)
        task.start_event.emit
        task.stop_event.emit
        assert_raises(Roby::CommandFailed) { task.stop! }
    end

    def test_intermediate_emit_failed
        model = Tasks::Simple.new_submodel do
            event :intermediate
        end
	plan.add(task = model.new)
        task.start!

        task.intermediate_event.emit_failed
        assert(task.internal_error?)
        assert(task.failed?)
        assert_kind_of EmissionFailed, task.failure_reason
        assert_equal(task.intermediate_event, task.failure_reason.failed_generator)
    end

    def test_emergency_termination_fails
        model = Tasks::Simple.new_submodel do
            event :command_fails do |context|
                raise ArgumentError
            end
            event :emission_fails
        end
	plan.add(task = model.new)
        task.start!

        task.command_fails!
        assert(task.internal_error?)
        assert(task.failed?)
        assert_kind_of CommandFailed, task.failure_reason
        assert_equal(task.command_fails_event, task.failure_reason.failed_generator)

        plan.add(task = model.new)
        task.start!
        task.emission_fails_event.emit_failed
        assert(task.internal_error?)
        assert(task.failed?)
        assert_kind_of EmissionFailed, task.failure_reason
    end

    def test_emergency_termination_in_terminal_commands
        mock = flexmock
        mock.should_expect do |m|
            m.cmd_stop.once.ordered
            m.cmd_failed.once.ordered
        end

        model = Tasks::Simple.new_submodel do
            event :failed, terminal: true do |context|
                mock.cmd_failed
                raise ArgumentError
            end
            event :stop, terminal: true do |context|
                mock.cmd_stop
                failed!
            end
        end
	plan.add(task = model.new)
        task.start!

        with_log_level(Roby, Logger::FATAL) do
            assert_raises(Roby::TaskEmergencyTermination) do
                task.stop!
            end
        end

    ensure
        if task
            task.forcefully_terminate
            plan.remove_task(task)
        end
    end

    def test_nil_default_argument
        model = Tasks::Simple.new_submodel do
            argument 'value', default: nil
        end
        task = model.new
        assert task.fully_instanciated?
        assert !task.arguments.static?
	plan.add(task)
	assert task.executable?
	task.start!
	assert_equal nil, task.arguments[:value]
    end

    def test_plain_default_argument
        model = Tasks::Simple.new_submodel do
            argument 'value', default: 10
        end
        task = model.new
        assert task.fully_instanciated?
        assert !task.arguments.static?
	plan.add(task)
	assert task.executable?
	task.start!
	assert_equal 10, task.arguments['value']
    end

    def test_delayed_default_argument
        has_value = false
        value = nil
        block = lambda do |task|
            if has_value
                value
            else
                throw :no_value
            end
        end

        model = Roby::Task.new_submodel do
            terminates
            argument 'value', default: (Roby::DelayedTaskArgument.new(&block))
        end
        task = model.new
        assert !task.arguments.static?

        assert_equal nil, task.value
        assert !task.fully_instanciated?
        has_value = true
        assert_equal nil, task.value
        assert task.fully_instanciated?

        value = 10
        assert task.fully_instanciated?
        has_value = false
        assert_equal nil, task.value
        assert !task.fully_instanciated?

        has_value = true
        plan.add(task)
        task.start!
        assert_equal 10, task.arguments[:value]
        assert_equal 10, task.value
    end

    def test_delayed_argument_from_task
        value_obj = Class.new do
            attr_accessor :value
        end.new

        klass = Roby::Task.new_submodel do
            terminates
            argument :arg, default: from(:planned_task).arg.of_type(Numeric)
        end

        planning_task = klass.new
        planned_task  = klass.new
        planned_task.planned_by planning_task
        plan.add(planned_task)

        assert !planning_task.arguments.static?
        assert !planning_task.fully_instanciated?
        planned_task.arg = Object.new
        assert !planning_task.fully_instanciated?
        plan.force_replace_task(planned_task, (planned_task = klass.new))
        planned_task.arg = 10
        assert planning_task.fully_instanciated?
        planning_task.start!
        assert_equal 10, planning_task.arg
    end

    def test_delayed_argument_from_object
        value_obj = Class.new do
            attr_accessor :value
        end.new

        klass = Roby::Task.new_submodel do
            terminates
            argument :arg
        end
        task = klass.new(arg: Roby.from(value_obj).value.of_type(Integer))
        plan.add(task)

        assert !task.arguments.static?
        assert !task.fully_instanciated?
        value_obj.value = 10
        assert task.fully_instanciated?
        assert_equal nil, task.arg
        value_obj.value = 20
        task.start!
        assert_equal 20, task.arg
    end

    def test_as_plan
        plan.add(task = Tasks::Simple.new)
        model = Tasks::Simple.new_submodel

        child = task.depends_on(model)
        assert_kind_of model, child
        assert task.depends_on?(child)
    end

    def test_as_plan_with_arguments
        plan.add(task = Tasks::Simple.new)
        model = Tasks::Simple.new_submodel

        child = task.depends_on(model.with_arguments(id: 20))
        assert_kind_of model, child
        assert_equal 20, child.arguments[:id]
        assert task.depends_on?(child)
    end

    def test_can_merge_model
        test_model1 = Roby::Task.new_submodel
        test_model2 = Roby::Task.new_submodel
        test_model3 = test_model1.new_submodel

        t1 = test_model1.new
        t2 = test_model2.new
        t3 = test_model3.new

        assert(t1.can_merge?(t1))
        assert(t3.can_merge?(t1))
        assert(!t1.can_merge?(t3))
        assert(!t1.can_merge?(t2))

        assert(!t3.can_merge?(t2))
        assert(!t2.can_merge?(t3))
    end

    def test_can_merge_arguments
        test_model = Roby::Task.new_submodel do
            argument :id
        end
        t1 = test_model.new
        t2 = test_model.new

        assert(t1.can_merge?(t2))
        assert(t2.can_merge?(t1))

        t2.arguments[:id] = 10
        assert(t1.can_merge?(t2))
        assert(t2.can_merge?(t1))

        t1.arguments[:id] = 20
        assert(!t1.can_merge?(t2))
        assert(!t2.can_merge?(t1))
    end

    def test_execute_handlers_with_replacing
        model = Roby::Task.new_submodel do
            terminates
        end
        old, new = prepare_plan missions: 2, model: model

        FlexMock.use do |mock|
            old.execute { |task| mock.should_not_be_passed_on(task) }
            old.execute(on_replace: :copy) { |task| mock.should_be_passed_on(task) }

            plan.replace(old, new)

            assert_equal(1, new.execute_handlers.size)
            assert_equal(new.execute_handlers[0].block, old.execute_handlers[1].block)

            mock.should_receive(:should_not_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(new).once
            old.start!
            new.start!

            process_events
        end
    end

    def test_poll_handlers_with_replacing
        model = Roby::Task.new_submodel do
            terminates
        end
        old, new = prepare_plan missions: 2, model: model

        FlexMock.use do |mock|
            mock.should_receive(:should_not_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(new).once
            old.poll { |task| mock.should_not_be_passed_on(task) }
            old.poll(on_replace: :copy) { |task| mock.should_be_passed_on(task) }

            plan.replace(old, new)

            assert_equal(1, new.poll_handlers.size)
            assert_equal(new.poll_handlers[0].block, old.poll_handlers[1].block)

            old.start!
            new.start!
        end
    end

    def test_poll_is_called_while_the_task_is_running
        test_case = self
        model = Roby::Task.new_submodel do
            terminates

            poll do
                test_case.assert running?
            end
        end
        plan.add(task = model.new)
        task.start!
    end

    def test_event_handlers_with_replacing
        model = Roby::Task.new_submodel do
            terminates
        end
        old, new = prepare_plan missions: 2, model: model

        FlexMock.use do |mock|
            mock.should_receive(:should_be_passed_on).with(new).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_not_be_passed_on).with(old).once

            old.start_event.on { |event| mock.should_not_be_passed_on(event.task) }
            old.start_event.on(on_replace: :copy) { |event| mock.should_be_passed_on(event.task) }

            plan.replace(old, new)

            assert_equal(1, new.start_event.handlers.size)
            assert_equal(new.start_event.handlers[0].block, old.start_event.handlers[1].block)

            old.start!
            new.start!
        end
    end

    def test_abstract_tasks_automatically_mark_the_poll_handlers_as_replaced
        abstract_model = Roby::Task.new_submodel do
            abstract

            def fullfilled_model
                [Roby::Task]
            end
        end
        plan.add_permanent_task(old = abstract_model.new)
        plan.add_permanent_task(new = Roby::Tasks::Simple.new)

        FlexMock.use do |mock|
            mock.should_receive(:should_be_passed_on).with(new).twice

            old.poll { |task| mock.should_be_passed_on(task) }
            old.poll(on_replace: :drop) { |task| mock.should_not_be_passed_on(task) }

            plan.replace(old, new)
            new.start!

            assert_equal(1, new.poll_handlers.size, new.poll_handlers.map(&:block))
            assert_equal(new.poll_handlers[0].block, old.poll_handlers[0].block)
            process_events
        end
    end

    def test_abstract_tasks_automatically_mark_the_event_handlers_as_replaced
        abstract_model = Roby::Task.new_submodel do
            abstract

            def fullfilled_model
                [Roby::Task]
            end
        end
        plan.add_mission_task(old = abstract_model.new)
        plan.add_mission_task(new = Roby::Tasks::Simple.new)

        FlexMock.use do |mock|
            old.start_event.on { |event| mock.should_be_passed_on(event.task) }
            old.start_event.on(on_replace: :drop) { |event| mock.should_not_be_passed_on(event.task) }

            plan.replace(old, new)
            assert_equal(1, new.start_event.handlers.size)
            assert_equal(new.start_event.handlers[0].block, old.start_event.handlers[0].block)

            mock.should_receive(:should_not_be_passed_on).never
            mock.should_receive(:should_be_passed_on).with(new).once
            new.start!
        end
    end

    def test_finalization_handlers_with_replacing
        model = Roby::Task.new_submodel do
            terminates
        end
        old, new = prepare_plan missions: 2, model: model

        FlexMock.use do |mock|
            mock.should_receive(:should_not_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(new).once

            old.when_finalized { |task| mock.should_not_be_passed_on(task) }
            old.when_finalized(on_replace: :copy) { |task| mock.should_be_passed_on(task) }

            plan.replace(old, new)
            assert_equal(1, new.finalization_handlers.size)
            assert_equal(new.finalization_handlers[0].block, old.finalization_handlers[1].block)

            plan.remove_task(old)
            plan.remove_task(new)
        end
    end

    def test_finalization_handlers_are_copied_by_default_on_abstract_tasks
        model = Roby::Task.new_submodel do
            terminates
        end
        old = prepare_plan add: 1, model: Roby::Task
        new = prepare_plan add: 1, model: model

        FlexMock.use do |mock|
            mock.should_receive(:should_not_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(old).once
            mock.should_receive(:should_be_passed_on).with(new).once

            old.when_finalized(on_replace: :drop) { |task| mock.should_not_be_passed_on(task) }
            old.when_finalized { |task| mock.should_be_passed_on(task) }

            plan.replace(old, new)
            assert_equal(1, new.finalization_handlers.size)
            assert_equal(new.finalization_handlers[0].block, old.finalization_handlers[1].block)

            plan.remove_task(old)
            plan.remove_task(new)
        end
    end

    def test_plain_all_and_root_sources
        source, target = prepare_plan add: 2, model: Roby::Tasks::Simple
        source.stop_event.forward_to target.aborted_event

        source.start!
        target.start!
        source.stop!
        event = target.stop_event.last

        assert_equal [target.failed_event].map(&:last).to_set, event.sources.to_set
        assert_equal [source.failed_event, source.stop_event, target.aborted_event, target.failed_event].map(&:last).to_set, event.all_sources.to_set
        assert_equal [source.failed_event].map(&:last).to_set, event.root_sources.to_set

        assert_equal [target.failed_event].map(&:last).to_set, event.task_sources.to_set
        assert_equal [target.aborted_event, target.failed_event].map(&:last).to_set, event.all_task_sources.to_set
        assert_equal [target.aborted_event].map(&:last).to_set, event.root_task_sources.to_set
    end

    def test_task_as_plan
        task_t = Roby::Task.new_submodel
        task, planner_task = task_t.new, task_t.new
        task.planned_by planner_task
        flexmock(Roby.app).should_receive(:prepare_action).with(task_t, Hash.new).and_return([task, planner_task])

        plan.add(as_plan = task_t.as_plan)
        assert_same task, as_plan
    end

    def test_emit_failed_on_start_event_causes_the_task_to_be_marked_as_failed_to_start
        plan.add(task = Roby::Tasks::Simple.new)
        task.start_event.emit_failed
        assert task.failed_to_start?
    end

    def test_raising_an_EmissionFailed_error_in_calling_causes_the_task_to_be_marked_as_failed_to_start
        plan.add(task = Tasks::Simple.new)
        e = EmissionFailed.new(nil, task.start_event)
        flexmock(task.start_event).should_receive(:calling).and_raise(e)
        assert_raises(EmissionFailed) { task.start! }
        assert task.failed_to_start?
    end

    def test_raising_a_CommandFailed_error_in_calling_causes_the_task_to_be_marked_as_failed_to_start
        plan.add(task = Tasks::Simple.new)
        e = CommandFailed.new(nil, task.start_event)
        flexmock(task.start_event).should_receive(:calling).and_raise(e)
        assert_raises(CommandFailed) { task.start! }
        assert task.failed_to_start?
    end

    def test_start_command_raises_before_emission
        klass = Roby::Tasks::Simple.new_submodel do
            event :start do |context|
                if context == [true]
                    raise ArgumentError
                end
                start_event.emit
            end
        end
        plan.add(task = klass.new)
        with_log_level(Roby, Logger::FATAL) do
            assert_raises(Roby::CommandFailed) do
                task.start!(true)
            end
        end
        assert(task.failed_to_start?, "#{task} is not marked as failed to start but should be")
        assert(task.failed?)
    end

    def test_start_command_raises_after_emission
        klass = Roby::Tasks::Simple.new_submodel do
            event :start do |context|
                start_event.emit
                raise ArgumentError
            end
        end
        plan.add(task = klass.new)
        with_log_level(Roby, Logger::FATAL) do
            task.start!
        end
        assert(!task.failed_to_start?, "#{task} is marked as failed to start but should not be")
        assert(!task.executable?)
        assert(task.internal_error?)
        assert(!task.running?)
    end

    def test_new_tasks_are_reusable
        assert Roby::Task.new.reusable?
    end
    def test_do_not_reuse
        task = Roby::Task.new
        task.do_not_reuse
        assert !task.reusable?
    end
    def test_running_tasks_are_reusable
        task = Roby::Task.new
        flexmock(task).should_receive(:running?).and_return(true)
        assert task.reusable?
    end
    def test_finishing_tasks_are_not_reusable
        task = Roby::Task.new
        flexmock(task).should_receive(:finishing?).and_return(true)
        assert !task.reusable?
    end
    def test_finished_tasks_are_not_reusable
        task = Roby::Task.new
        flexmock(task).should_receive(:finished?).and_return(true)
        assert !task.reusable?
    end
    def test_reusable_propagation_to_transaction
        plan.add(task = Roby::Task.new)
        plan.in_transaction do |trsc|
            assert trsc[task].reusable?
        end
    end
    def test_do_not_reuse_propagation_to_transaction
        plan.add(task = Roby::Task.new)
        task.do_not_reuse
        plan.in_transaction do |trsc|
            assert !trsc[task].reusable?
        end
    end
    def test_do_not_reuse_propagation_from_transaction
        plan.add(task = Roby::Task.new)
        plan.in_transaction do |trsc|
            proxy = trsc[task]
            assert proxy.reusable?
            proxy.do_not_reuse
            assert !proxy.reusable?
            assert task.reusable?
            trsc.commit_transaction
        end
        assert !task.reusable?
    end
    def test_model_terminal_event_forces_terminal
        task_model = Roby::Task.new_submodel do
            event :terminal, terminal: true
        end
        plan.add(task = task_model.new)
        assert(task.event(:terminal).terminal?)
    end

    def test_add_error_propagates_it_using_process_events_synchronous
        error_m = Class.new(LocalizedError)
        error = error_m.new(Roby::Task.new)
        error = error.to_execution_exception
        flexmock(execution_engine).should_receive(:process_events_synchronous).with([], [error]).once
        execution_engine.add_error(error)
    end

    def test_unreachable_handlers_are_called_after_on_stop
        task_m = Roby::Task.new_submodel do
            terminates
            event :intermediate
        end
        recorder = flexmock
        plan.add(task = task_m.new)
        task.stop_event.on do
            recorder.on_stop
        end
        task.intermediate_event.when_unreachable do
            recorder.when_unreachable
        end
        recorder.should_receive(:on_stop).once.ordered
        recorder.should_receive(:when_unreachable).once.ordered
        task.start!
        task.stop!
    end

    def test_event_to_execution_exception_matcher_matches_the_event_specifically
        plan.add(task = Roby::Task.new)
        matcher = task.stop_event.to_execution_exception_matcher
        assert(matcher === LocalizedError.new(task.stop_event).to_execution_exception)
        assert(!(matcher === LocalizedError.new(Roby::Task.new.stop_event).to_execution_exception))
    end

    def test_has_argument_p_returns_true_if_the_argument_is_set
        task_m = Roby::Task.new_submodel { argument :arg }
        plan.add(task = task_m.new(arg: 10))
        assert task.has_argument?(:arg)
    end
    def test_has_argument_p_returns_true_if_the_argument_is_set_with_nil
        task_m = Roby::Task.new_submodel { argument :arg }
        plan.add(task = task_m.new(arg: nil))
        assert task.has_argument?(:arg)
    end
    def test_has_argument_p_returns_false_if_the_argument_is_not_set
        task_m = Roby::Task.new_submodel { argument :arg }
        plan.add(task = task_m.new)
        assert !task.has_argument?(:arg)
    end
    def test_has_argument_p_returns_false_if_the_argument_is_a_delayed_argument
        task_m = Roby::Task.new_submodel { argument :arg }
        delayed_arg = flexmock(evaluate_delayed_argument: nil)
        plan.add(task = task_m.new(arg: delayed_arg))
        assert !task.has_argument?(:arg)
    end

    def test_it_does_not_call_the_setters_for_delayed_arguments
        task_m = Roby::Task.new_submodel { argument :arg }
        flexmock(task_m).new_instances.should_receive(:arg=).never
        plan.add(task_m.new(arg: flexmock(:evaluate_delayed_argument)))
    end

    def test_it_calls_the_setters_when_delayed_arguments_are_resolved
        task_m = Roby::Task.new_submodel { argument :arg }
        flexmock(task_m).new_instances.should_receive(:arg=).once.with(10)
        arg = Class.new do
            def evaluate_delayed_argument(task); 10 end
        end.new
        plan.add(task = task_m.new(arg: arg))
        task.freeze_delayed_arguments
    end
end

