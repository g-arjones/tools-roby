require 'roby/test/self'

module Roby
    module Models
        describe Task do
            it "registers its submodels on the Task class" do
                subclass = Roby::Task.new_submodel
                assert_equal Roby::Task, subclass.supermodel
                assert Roby::Task.each_submodel.to_a.include?(subclass)
            end

            it "provides task services" do
                tag = TaskService.new_submodel
                task = Roby::Task.new_submodel
                task.provides tag
                assert task.fullfills?(tag)
            end

            it "has the arguments of provided task services" do
                tag = TaskService.new_submodel { argument :service_arg }
                task = Roby::Task.new_submodel
                task.provides tag
                assert task.has_argument?(:service_arg)
            end

            describe "abstract-ness" do
                describe Roby::Task do
                    it "is abstract" do
                        assert Roby::Task.abstract?
                    end
                end

                it "does not define submodels as abstract by default" do
                    assert !Roby::Task.new_submodel.abstract?
                end

                it "uses #abstract to mark models as abstract" do
                    submodel = Roby::Task.new_submodel
                    submodel.abstract
                    assert submodel.abstract?
                end
            end

            describe "access to events" do
                it "gives access through the _event method suffix" do
                    model = Roby::Task.new_submodel do
                        event :custom
                        event :other
                    end
                    event_model = model.custom_event
                    assert_same model.find_event_model('custom'), event_model
                end
            end
        end
    end
end

