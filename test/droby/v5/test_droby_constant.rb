require 'roby/test/self'

module Roby
    module DRoby
        module V5
            class DRobyConstantTestObject
                extend DRobyConstant::Dump
            end

            describe DRobyConstant do
                it "dumps and resolves a class by name" do
                    marshalled = DRobyConstantTestObject.droby_dump(flexmock)
                    assert_equal "Roby::DRoby::V5::DRobyConstantTestObject", marshalled.name
                    assert_same DRobyConstantTestObject, marshalled.proxy(flexmock)
                end

                it "caches whether a constant can be properly resolved" do
                    marshalled = DRobyConstantTestObject.droby_dump(flexmock)
                    flexmock(DRobyConstantTestObject).should_receive(:constant).never
                    assert_same marshalled, DRobyConstantTestObject.droby_dump(flexmock)
                end

                it "raises if the constant resolves to another object" do
                    obj = flexmock(name: "Roby::DRoby")
                    obj.singleton_class.include DRobyConstant::Dump
                    assert_raises(ArgumentError) do
                        obj.droby_dump(flexmock)
                    end
                end

                it "raises on dump if the object's name cannot be resolved" do
                    obj = flexmock(name: "Does::Not::Exist")
                    obj.singleton_class.include DRobyConstant::Dump
                    assert_raises(ArgumentError) do
                        obj.droby_dump(flexmock)
                    end
                end

                it "raises on dump if the object's name is not a valid constant name" do
                    obj = flexmock(name: "0_does.not_exist")
                    obj.singleton_class.include DRobyConstant::Dump
                    assert_raises(ArgumentError) do
                        obj.droby_dump(flexmock)
                    end
                end
            end
        end
    end
end

