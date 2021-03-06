require 'roby/test/self'

module Roby
    describe ExecutablePlan do
        describe "DAG graphs" do
            attr_reader :graph, :graph_m, :chain

            def prepare(dag)
                graph_m = Relations::Graph.new_submodel(dag: dag)
                @graph = graph_m.new(observer: ExecutablePlan.new)
                vertex_m = Class.new do
                    include Relations::DirectedRelationSupport
                    attr_reader :relation_graphs
                    def initialize(relation_graphs = Hash.new)
                        @relation_graphs = relation_graphs
                    end
                    def read_write?; true end
                end
                @chain = (1..10).map { vertex_m.new(graph => graph, graph_m => graph) }
                chain.each_cons(2) { |a, b| graph.add_relation(a, b, nil) }
            end

            it "does not raise CycleFoundError if an edge creates a cycle if dag is false" do
                prepare(false)
                graph.add_relation(chain[-1], chain[0])
            end
            it "raises CycleFoundError if an edge creates a DAG if dag is true" do
                prepare(true)
                assert_raises(Relations::CycleFoundError) do
                    graph.add_relation(chain[-1], chain[0])
                end
            end
        end

        describe "edge hooks" do
            it "calls the relation hooks on #replace" do
                (p, c1), (c11, c12, c2, c3) = prepare_plan missions: 2, tasks: 4, model: Roby::Tasks::Simple
                p.depends_on c1, model: Roby::Tasks::Simple
                c1.depends_on c11
                c1.depends_on c12
                p.depends_on c2
                c1.stop_event.signals c2.start_event
                c1.start_event.forward_to c1.stop_event
                c11.success_event.forward_to c1.success_event

                # Replace c1 by c3 and check that the hooks are properly called
                FlexMock.use do |mock|
                    p.singleton_class.class_eval do
                        define_method('removed_child') do |child|
                            mock.removed_hook(self, child)
                        end
                    end

                    mock.should_receive(:removed_hook).with(p, c1).once
                    mock.should_receive(:removed_hook).with(p, c2)
                    mock.should_receive(:removed_hook).with(p, c3)
                    plan.replace(c1, c3)
                end
            end

            it "calls the relation hooks on #replace_task" do
                (p, c1), (c11, c12, c2, c3) = prepare_plan missions: 2, tasks: 4, model: Roby::Tasks::Simple
                p.depends_on c1, model: Roby::Tasks::Simple
                c1.depends_on c11
                c1.depends_on c12
                p.depends_on c2
                c1.stop_event.signals c2.start_event
                c1.start_event.forward_to c1.stop_event
                c11.success_event.forward_to c1.success_event

                # Replace c1 by c3 and check that the hooks are properly called
                FlexMock.use do |mock|
                    p.singleton_class.class_eval do
                        define_method('removed_child') do |child|
                            mock.removed_hook(self, child)
                        end
                    end

                    mock.should_receive(:removed_hook).with(p, c1).once
                    mock.should_receive(:removed_hook).with(p, c2)
                    mock.should_receive(:removed_hook).with(p, c3)
                    plan.replace_task(c1, c3)
                end
            end

            it "properly synchronize plans on relation addition even if the adding hook raises" do
                model = Task.new_submodel
                t1, t2 = model.new, model.new
                flexmock(t1).should_receive(:adding_child).and_raise(RuntimeError)

                plan.add_mission_task(t1)
                assert_equal(plan, t1.plan)
                assert_raises(RuntimeError) do
                    t1.depends_on t2
                end
                assert_equal(plan, t1.plan)
                assert_equal(plan, t2.plan)
                assert(plan.has_task?(t2))
            end

            describe "generic hook dispatching" do
                def expect_hooks_called(ing_hook, ed_hook, parent, child, *args)
                    on_child  = on { |t| t == child && t.plan == plan }
                    on_parent = on { |t| t == parent && t.plan == plan }

                    flexmock(parent).should_receive(ing_hook).
                        with(on_child, *args).once.ordered
                    flexmock(child).should_receive("#{ing_hook}_parent").
                        with(on_parent, *args).once.ordered
                    yield if block_given?
                    flexmock(parent).should_receive(ed_hook).
                        with(on_child, *args).once.ordered
                    flexmock(child).should_receive("#{ed_hook}_parent").
                        with(on_parent, *args).once.ordered
                end

                it "calls added_CHILD_NAME and adding_CHILD_NAME and the corresponding parent hooks on addition" do
                    parent, child = prepare_plan add: 2
                    expect_hooks_called("adding_child", "added_child", parent, child, Hash) do
                        flexmock(parent.relation_graph_for(Roby::TaskStructure::Dependency)).
                            should_receive(:add_edge).with(parent, child, Hash).once.ordered
                    end
                    parent.depends_on child
                end

                it "calls added_, adding_ and corresponding parent hooks on plan merge" do
                    parent, child = prepare_plan tasks: 2
                    parent.depends_on child
                    expect_hooks_called("adding_child", "added_child", parent, child, Hash)
                    plan.add(parent)
                end

                it "calls added_, adding_ and corresponding parent hooks when everything is added from a transaction" do
                    parent, child = prepare_plan tasks: 2
                    plan.in_transaction do |trsc|
                        parent.depends_on child
                        trsc.add(parent)
                        expect_hooks_called("adding_child", "added_child", parent, child, Hash)
                        trsc.commit_transaction
                    end
                end

                it "calls added_, adding_ and corresponding parent hooks when a relation is created within a transaction" do
                    parent, child = prepare_plan add: 2
                    plan.in_transaction do |trsc|
                        trsc[parent].depends_on trsc[child]
                        expect_hooks_called("adding_child", "added_child", parent, child, Hash)
                        trsc.commit_transaction
                    end
                end

                it "does not add the edge if adding_CHILD_NAME raises" do
                    parent, child = prepare_plan add: 2
                    flexmock(parent).should_receive(:adding_child).
                        with(child, Hash).once.
                        and_raise(ArgumentError)
                    assert_raises(ArgumentError) { parent.depends_on child }
                    assert !parent.depends_on?(child)
                end
                it "adds the edge even if added_CHILD_NAME raises" do
                    parent, child = prepare_plan add: 2
                    flexmock(parent).should_receive(:added_child).
                        with(child, Hash).once.
                        and_raise(ArgumentError)
                    assert_raises(ArgumentError) { parent.depends_on child }
                    assert parent.depends_on?(child)
                end
                it "calls the updating_ and updated_ hooks on update" do
                    parent, child = prepare_plan add: 2
                    parent.depends_on child
                    expect_hooks_called("updating_child", "updated_child", parent, child, Hash)
                    parent.depends_on child, role: 'test'
                end
                it "calls the updating_ and updated_ hooks on update within a transaction" do
                    parent, child = prepare_plan add: 2
                    parent.depends_on child
                    expect_hooks_called("updating_child", "updated_child", parent, child, Hash)
                    plan.in_transaction do |trsc|
                        trsc[parent].depends_on trsc[child], role: 'test'
                        trsc.commit_transaction
                    end
                end
                it "calls removed_CHILD_NAME and removing_CHILD_NAME on removal" do
                    parent, child = prepare_plan add: 2
                    parent.depends_on child
                    expect_hooks_called("removing_child", "removed_child", parent, child) do
                        flexmock(parent.relation_graph_for(TaskStructure::Dependency)).
                            should_receive(:remove_edge).with(parent, child).once.ordered
                    end
                    parent.remove_child child
                end
                it "calls removed_CHILD_NAME and removing_CHILD_NAME on removal from a transaction" do
                    parent, child = prepare_plan add: 2
                    parent.depends_on child
                    plan.in_transaction do |trsc|
                        trsc[parent].remove_child trsc[child]
                        expect_hooks_called("removing_child", "removed_child", parent, child)
                        trsc.commit_transaction
                    end
                end
                it "does not remove the edge if adding_CHILD_NAME raises" do
                    parent, child = prepare_plan add: 2
                    parent.depends_on child
                    flexmock(parent).should_receive(:removing_child).
                        with(child).once.
                        and_raise(ArgumentError)
                    assert_raises(ArgumentError) { parent.remove_child child }
                    assert parent.depends_on?(child)
                end
                it "removes the edge even if added_CHILD_NAME raises" do
                    parent, child = prepare_plan add: 2
                    parent.depends_on child
                    flexmock(parent).should_receive(:removed_child).
                        with(child).once.
                        and_raise(ArgumentError)
                    assert_raises(ArgumentError) { parent.remove_child child }
                    assert !parent.depends_on?(child)
                end
            end
        end
    end
end

