require 'roby/test/self'
require 'fakefs/safe'

describe Roby::Application do
    attr_reader :app, :app_dir
    before do
        @app = Roby::Application.new
        app.public_logs = false
        app.plugins_enabled = false
        app.base_setup
        register_plan(@app.plan)
        @app_dir = "/test/roby_app"
    end

    after do
        app.cleanup
    end

    describe "filesystem access and resolution" do
        before do
            FakeFS.activate!
            app.search_path = [app_dir]
            FileUtils.mkdir_p app_dir
        end

        after do
            FakeFS.deactivate!
            FakeFS::FileSystem.clear
        end

        describe "#make_path_relative" do
            before do
                app.search_path = %w{/bla/blo /bli/blu}
            end

            it "keeps absolute paths that are not in the search path as-is" do
                absolute_path = "/not/in/search/path"
                assert_equal(absolute_path, app.make_path_relative(absolute_path))
            end

            it "keeps absolute paths that are not present on disk as-is" do
                absolute_path = "/bla/blo/config/file"
                assert_equal(absolute_path, app.make_path_relative(absolute_path))
            end

            it "converts paths that are present on disk and are prefixed by an entry in search_path" do
                absolute_path = "/bla/blo/config/file"
                FileUtils.mkdir_p File.dirname(absolute_path)
                File.open(absolute_path, 'w').close
                assert_equal("config/file", app.make_path_relative(absolute_path))
            end
        end

        describe "#find_and_create_log_dir" do
            before do
                app.log_base_dir = '/path/to/logs'
            end

            it "creates the log directory and paths to it" do
                full_path = app.find_and_create_log_dir('tag')
                assert_equal '/path/to/logs/tag', full_path
                assert File.directory?(full_path)
            end
            it "saves the app metadata in the path" do
                app.find_and_create_log_dir('tag')
                metadata = YAML.load(File.read('/path/to/logs/tag/info.yml'))
                assert_equal 1, metadata.size
                assert(metadata.first == app.app_metadata, "#{metadata} differs from #{app.app_metadata}")
            end

            def assert_equal(expected, actual)
                assert(expected == actual, "#{expected} differs from #{actual}")
            end

            it "registers the created paths for later cleanup" do
                FileUtils.mkdir_p '/path'
                existing_dirs = app.created_log_dirs.to_set
                app.find_and_create_log_dir('tag')
                assert_equal ['/path/to', '/path/to/logs'].to_set,
                    app.created_log_base_dirs.to_set
                assert_equal existing_dirs | Set['/path/to/logs/tag'],
                    app.created_log_dirs.to_set
            end
            it "handles concurrent path creation properly" do
                FileUtils.mkdir_p '/path/to'
                flexmock(FileUtils).should_receive(:mkdir).with('/path/to/logs').pass_thru
                flexmock(FileUtils).should_receive(:mkdir).with('/path/to/logs/tag').
                    pass_thru { raise Errno::EEXIST }
                flexmock(FileUtils).should_receive(:mkdir).with('/path/to/logs/tag.1').pass_thru
                existing_dirs = app.created_log_dirs.to_set
                created = app.find_and_create_log_dir('tag')
                assert_equal '/path/to/logs/tag.1', created
                assert_equal [].to_set, app.created_log_base_dirs.to_set
                assert_equal existing_dirs | Set['/path/to/logs/tag.1'], app.created_log_dirs.to_set
            end
            it "sets app#time_tag to the provided time tag" do
                app.find_and_create_log_dir('tag')
                assert_equal 'tag', app.time_tag
            end
            it "sets app#log_dir to the created log dir" do
                full_path = app.find_and_create_log_dir('tag')
                assert_equal full_path, app.log_dir
            end
            it "handles existing log directories by appending .N suffixes" do
                FileUtils.mkdir_p '/path/to/logs/tag'
                FileUtils.mkdir_p '/path/to/logs/tag.1'
                full_path = app.find_and_create_log_dir('tag')
                assert_equal '/path/to/logs/tag.2', full_path
            end
        end

        describe "#test_file_for" do
            before do
                app.search_path = %w{/bla/blo /bla/blo/blu}
                FileUtils.mkdir_p "/bla/blo/models/compositions"
                FileUtils.touch "/bla/blo/models/compositions/file.rb"
                FileUtils.mkdir_p "/bla/blo/test/compositions"
                FileUtils.touch "/bla/blo/test/compositions/test_file.rb"
            end

            def assert_equal(expected, actual)
                assert expected == actual, "expected #{expected} to be equal to #{actual}"
            end

            it "returns a matching test file" do
                m = flexmock(definition_location: [['/bla/blo/models/compositions/file.rb', 120, :m]])
                assert_equal '/bla/blo/test/compositions/test_file.rb', app.test_file_for(m)
            end
            it "ignores entries not in the search path" do
                m = flexmock(definition_location: [['/bla/blo/models/compositions/file.rb', 120, :m]])
                app.search_path = []
                assert_equal nil, app.test_file_for(m)
            end
            it "ignores entries whose first element is not 'models'" do
                m = flexmock(definition_location: [['/bla/blo/models/compositions/file.rb', 120, :m]])
                app.search_path = ['/bla']
                assert_equal nil, app.test_file_for(m)
            end
            it "ignores entries that don't exist" do
                m = flexmock(definition_location: [['/bla/blo/models/compositions/file.rb', 120, :m]])
                FileUtils.rm_f "/bla/blo/test/compositions/test_file.rb"
                assert_equal nil, app.test_file_for(m)
            end
        end

        describe "#find_base_path_for" do
            before do
                app.search_path = %w{/bla/blo /bla/blo/blu}
            end

            it "returns nil if no entries in search_path matches" do
                assert_equal nil, app.find_base_path_for("/somewhere/else")
            end
            it "returns the matching entry in search_path" do
                assert_equal "/bla/blo", app.find_base_path_for("/bla/blo/models")
            end
            it "returns the longest matching entry in search_path if there are multiple candidates" do
                assert_equal "/bla/blo/blu", app.find_base_path_for("/bla/blo/blu/models")
            end
        end

        describe "#setup_robot_names_from_config_dir" do
            def robots_dir
                File.join(app_dir, 'config', 'robots')
            end

            describe "the backward-compatible behaviour" do
                it "does not the robot name resolution to strict if config/robots is empty" do
                    FileUtils.mkdir_p robots_dir
                    app.setup_robot_names_from_config_dir
                    assert !app.robots.strict?
                end
                it "does not set the robot name resolution to strict if config/robots does not exist" do
                    app.setup_robot_names_from_config_dir
                    assert !app.robots.strict?
                end
            end

            describe "the new behaviour" do
                before do
                    FileUtils.mkdir_p robots_dir
                    File.open(File.join(robots_dir, "test.rb"), 'w').close
                    app.setup_robot_names_from_config_dir
                end
                it "sets the robot name resolution to strict if config/robots has files" do
                    assert app.robots.strict?
                end
                it "registers the robots on #robots" do
                    assert app.robots.has_robot?('test')
                end
            end
        end
    end

    describe "#prepare_action" do
        it "resolves a task model into an action and adds the actions' #plan_pattern to the plan" do
            task_t = Roby::Task.new_submodel
            task, planner_task = task_t.new, task_t.new
            task.planned_by planner_task
            planner = flexmock
            planning_method = flexmock(plan_pattern: task)
            flexmock(app).should_receive(:action_from_model).with(task_t).and_return([planner, planning_method])

            assert_equal [task, planner_task], app.prepare_action(task_t)
            assert_same app.plan, task.plan
        end

        it "passes arguments to the action" do
            arguments = {id: 10}

            task_t = Roby::Task.new_submodel
            task, planner_task = task_t.new, task_t.new
            task.planned_by planner_task
            planner = flexmock
            planning_method = flexmock
            planning_method.should_receive(:plan_pattern).with(arguments).once.and_return(task)
            flexmock(app).should_receive(:action_from_model).with(task_t).and_return([planner, planning_method])

            assert_equal [task, planner_task], app.prepare_action(task_t, **arguments)
            assert_same app.plan, task.plan
        end
    end

    describe "#action_from_model" do
        attr_reader :planner
        attr_reader :task_m

        before do
            @planner = flexmock
            @task_m = Roby::Task.new_submodel
            app.planners << planner
        end

        it "raises ArgumentError if there are no matches" do
            planner.should_receive(:find_all_actions_by_type).once.
                with(task_m).and_return([])
            assert_raises(ArgumentError) { app.action_from_model(task_m) }
        end
        it "returns the action if there is a single match" do
            planner.should_receive(:find_all_actions_by_type).once.
                with(task_m).and_return([action = flexmock(name: 'A')])
            assert_equal [planner, action], app.action_from_model(task_m)
        end
        it "raises if there are more than one match" do
            planner.should_receive(:find_all_actions_by_type).once.
                with(task_m).and_return([flexmock(name: 'A'), flexmock(name: 'B')])
            assert_raises(ArgumentError) { app.action_from_model(task_m) }
        end
    end
end

