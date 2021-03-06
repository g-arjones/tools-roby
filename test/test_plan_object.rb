require 'roby/test/self'

class TC_PlanObject < Minitest::Test 
    def setup
        super
        Roby.app.filter_backtraces = false
    end

    def test_model_finalization_handler
        mockup_plan = ExecutablePlan.new
        FlexMock.use do |mock|
            klass = Class.new(PlanObject) do
                when_finalized do
                    mock.finalized(self)
                end
            end
            obj = klass.new
            obj.plan = mockup_plan

            mock.should_receive(:finalized).with(obj).once
            obj.finalized!
        end
    end

    def test_model_finalization_handler_on_non_executable_plan
        mockup_plan = Plan.new
        FlexMock.use do |mock|
            klass = Class.new(PlanObject) do
                when_finalized do
                    mock.finalized(self)
                end
            end
            obj = klass.new
            obj.plan = mockup_plan
            obj.when_finalized do
                mock.finalized
            end

            mock.should_receive(:finalized).with(obj).never
            obj.finalized!
        end
    end

    def test_finalization_handler
        plan = ExecutablePlan.new
        ExecutionEngine.new(plan)
        plan.add(obj = Task.new)

        FlexMock.use do |mock|
            obj.when_finalized do
                mock.finalized
            end
            mock.should_receive(:finalized).once
            plan.remove_task(obj)
        end
    end

    def test_plan_synchronization_adds_child_to_parents_plan
        plan = Roby::Plan.new
        plan.add(parent = Roby::Task.new)
        child = Roby::Task.new
        flexmock(plan).should_receive(:add).with(child).once.pass_thru
        parent.depends_on(child)
    end

    def test_plan_synchronization_adds_plan_to_childs_plan
        plan = Roby::Plan.new
        parent = Roby::Task.new
        plan.add(child = Roby::Task.new)
        flexmock(plan).should_receive(:add).with(parent).once.pass_thru
        child.depends_on(parent)
    end
end

