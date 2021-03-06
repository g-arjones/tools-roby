module Roby
    module DRoby
        module V5
            module ModelDumper
                def droby_dump(peer)
                    DRobyModel.new(
                        name,
                        peer.known_siblings_for(self),
                        DRobyModel.dump_supermodel(peer, self),
                        DRobyModel.dump_provided_models_of(peer, self))
                end
            end

            module ExceptionBaseDumper
                include Builtins::ExceptionDumper

                def droby_dump(peer)
                    droby = super(peer, droby_class: DRoby)
                    droby.original_exceptions.concat(peer.dump(original_exceptions))
                    droby
                end

                class DRoby < Builtins::ExceptionDumper::DRoby
                    attr_reader :original_exceptions

                    def initialize(exception_class, formatted_class, message = nil)
                        super
                        @original_exceptions = Array.new
                    end

                    def proxy(peer)
                        exception = super
                        exception.original_exceptions.
                            concat(peer.local_object(self.original_exceptions))
                        exception
                    end
                end
            end

            # Exception class used on the unmarshalling of LocalizedError for exception
            # classes that do not have their own marshalling
            class UntypedLocalizedError < LocalizedError
                attr_accessor :formatted_message
                attr_accessor :exception_class

                def initialize(failure_point, fatal: nil)
                    super(failure_point)
                    @fatal = fatal
                end

                def fatal?
                    @fatal
                end

                def pretty_print(pp)
                    pp.seplist(formatted_message) do |line|
                        pp.text line
                    end
                end

                def kind_of?(obj)
                    exception_class <= obj
                end
            end

            module LocalizedErrorDumper
                # Returns an intermediate representation of +self+ suitable to be sent to
                # the +dest+ peer.
                def droby_dump(peer)
                    formatted = Roby.format_exception(self)
                    DRoby.new(peer.dump(self.class),
                              peer.dump(failure_point),
                              fatal?,
                              message,
                              backtrace,
                              peer.dump(original_exceptions),
                              formatted)
                end

                # Intermediate representation used to marshal/unmarshal a LocalizedError
                class DRoby
                    attr_reader :model, :failure_point, :fatal, :message, :backtrace,
                        :original_exceptions, :formatted_message
                    def initialize(model, failure_point, fatal, message, backtrace,
                                   original_exceptions, formatted_message = [])
                        @model, @failure_point, @fatal, @message, @backtrace,
                            @original_exceptions, @formatted_message =
                            model, failure_point, fatal, message, backtrace,
                            original_exceptions, formatted_message
                    end

                    def proxy(peer)
                        failure_point = peer.local_object(self.failure_point)
                        error = UntypedLocalizedError.new(failure_point, fatal: fatal)
                        error = error.exception(message)
                        error.original_exceptions.concat(peer.local_object(original_exceptions))
                        error.set_backtrace(backtrace)
                        error.exception_class = peer.local_object(model)
                        error.formatted_message = formatted_message
                        error
                    end
                end
            end

            module PlanningFailedErrorDumper
                def droby_dump(peer)
                    DRoby.new(peer.dump(planned_task),
                              peer.dump(planning_task),
                              peer.dump(failure_reason))
                end

                class DRoby
                    attr_reader :planned_task
                    attr_reader :planning_task
                    attr_reader :failure_reason
                    def initialize(planned_task, planning_task, failure_reason)
                        @planned_task  = planned_task
                        @planning_task = planning_task
                        @failure_reason = failure_reason
                    end
                    def proxy(peer)
                        planned_task  = peer.local_object(self.planned_task)
                        planning_task = peer.local_object(self.planning_task)
                        failure_reason = peer.local_object(self.failure_reason)
                        PlanningFailedError.new(planned_task, planning_task, failure_reason: failure_reason)
                    end
                end
            end

            module ExecutionExceptionDumper
                def droby_dump(peer)
                    DRoby.new(peer.dump(trace),
                              peer.dump(exception),
                              handled)
                end

                class DRoby
                    attr_reader :trace
                    attr_reader :exception
                    attr_reader :handled

                    def initialize(trace, exception, handled)
                        @trace, @exception, @handled = trace, exception, handled
                    end

                    def proxy(peer)
                        trace     = peer.local_object(self.trace)
                        exception = peer.local_object(self.exception)
                        result = ExecutionException.new(exception)
                        result.trace.clear
                        result.trace.concat(trace)
                        result.handled = self.handled
                        result
                    end
                end
            end

            module Models
                module TaskDumper
                    # Used to tag anything that is extended by TaskDumper as
                    # "ready to be dumped"
                    include ModelDumper

                    def droby_dump(peer)
                        DRoby.new(
                            name,
                            peer.known_siblings_for(self),
                            argument_set,
                            DRobyModel.dump_supermodel(peer, self),
                            DRobyModel.dump_provided_models_of(peer, self),
                            each_event.map { |_, ev| [ev.symbol, ev.controlable?, ev.terminal?] })
                    end

                    class DRoby < DRobyModel
                        attr_reader :events
                        attr_reader :argument_set

                        def initialize(name, remote_siblings, argument_set, supermodel, provided_models, events)
                            super(name, remote_siblings, supermodel, provided_models)
                            @argument_set = argument_set
                            @events = events
                        end

                        def update(peer, local_object, fresh_proxy: false)
                            argument_set.each do |arg_name|
                                if !local_object.has_argument?(arg_name)
                                    local_object.argument arg_name
                                end
                            end
                            events.each do |name, controlable, terminal|
                                if !local_object.has_event?(name)
                                    local_object.event name, controlable: controlable, terminal: terminal
                                end
                            end
                        end
                    end
                end

                module TaskServiceModelDumper
                    include ModelDumper
                end
            end

            module DistributedObjectDumper
                class DRoby
                    # The set of remote siblings for that object, as known by the peer who
                    # called #droby_dump. This is used to match object identity among plan
                    # managers.
                    attr_reader :remote_siblings
                    # The set of owners for that object.
                    attr_reader :owners
                    # Create a DistributedObject::DRoby object with the given information
                    def initialize(remote_siblings, owners)
                        @remote_siblings, @owners = remote_siblings, owners
                    end

                    # Update an existing proxy, using the information stored in this DRoby
                    # object.
                    def update(peer, proxy, fresh_proxy: false)
                        proxy.owners.clear
                        owners.each do |m_owner|
                            proxy.owners << peer.local_object(m_owner)
                        end
                    end
                end
            end

            # Base class for all marshalled plan objects.
            module PlanObjectDumper
                class DRoby < DistributedObjectDumper::DRoby
                    # The model for this plan object
                    attr_reader :model
                    # The droby_id of this object's plan
                    attr_reader :plan_id

                    # Create a DRoby object with the given information
                    #
                    # @see DistributedObject::DRoby
                    def initialize(remote_siblings, owners, model, plan_id)
                        super(remote_siblings, owners)
                        @model, @plan_id = model, plan_id
                    end
                end
            end

            module EventGeneratorDumper
                # Returns an intermediate representation of +self+ suitable to be sent
                # to the +dest+ peer.
                def droby_dump(peer)
                    DRoby.new(peer.known_siblings_for(self),
                              peer.dump(owners),
                              peer.dump(model),
                              plan.droby_id,
                              controlable?, emitted?)
                end

                # An intermediate representation of EventGenerator objects suitable to
                # be sent to our peers.
                class DRoby < PlanObjectDumper::DRoby
                    # True if the generator is controlable
                    attr_reader :controlable
                    # True if the generator has already been emitted once at the time
                    # EventGenerator#droby_dump has been called.
                    attr_reader :emitted

                    # Create a DRoby object with the given information.  See also
                    # PlanObject::DRoby
                    def initialize(remote_siblings, owners, model, plan_id, controlable, emitted)
                        super(remote_siblings, owners, model, plan_id)
                        @controlable, @emitted = controlable, emitted
                    end

                    # Create a new proxy which maps the object of +peer+ represented by
                    # this communication intermediate.
                    def proxy(peer)
                        local_object = peer.local_object(model).new(plan: peer.local_plan(plan_id))
                        if controlable
                            local_object.command = lambda { } 
                        end
                        local_object
                    end

                    # Updates an already existing proxy using the information contained
                    # in this object.
                    def update(peer, proxy, fresh_proxy: false)
                        super

                        if emitted && !proxy.emitted?
                            proxy.instance_eval { @emitted = true }
                        end
                    end
                end
            end

            module EventDumper
                # Returns an intermediate representation of +self+ suitable to be sent
                # to the +dest+ peer.
                def droby_dump(dest)
                    DRoby.new(propagation_id, time, dest.dump(generator), dest.dump(context))
                end

                class DRoby
                    attr_reader :propagation_id
                    attr_reader :time
                    attr_reader :generator
                    attr_reader :context

                    def initialize(propagation_id, time, generator, context)
                        @propagation_id, @time, @generator, @context = propagation_id, time, generator, context
                    end

                    def proxy(peer)
                        generator = peer.local_object(self.generator)
                        context   = peer.local_object(self.context)
                        generator.new(context, propagation_id, time)
                    end
                end
            end

            module TaskEventGeneratorDumper
                # Returns an intermediate representation of +self+ suitable to be sent
                # to the +dest+ peer.
                def droby_dump(peer)
                    DRoby.new(peer.known_siblings_for(self), emitted?, peer.dump(task), symbol)
                end

                # An intermediate representation of TaskEventGenerator objects suitable
                # to be sent to our peers.
                class DRoby
                    # This event's siblings
                    attr_reader :remote_siblings
                    # True if the generator has already emitted once at the time
                    # TaskEventGenerator#droby_dump has been called.
                    attr_reader :emitted
                    # An object representing the task of this generator on our remote
                    # peer.
                    attr_reader :task
                    # The event name
                    attr_reader :symbol

                    # Create a new DRoby object with the given information
                    def initialize(remote_siblings, emitted, task, symbol)
                        @remote_siblings = remote_siblings
                        @emitted = emitted
                        @task   = task
                        @symbol = symbol
                    end

                    def to_s # :nodoc:
                        "#<dRoby:#{task}/#{symbol}>"
                    end

                    # Create a new proxy which maps the object of +peer+ represented by
                    # this communication intermediate.
                    def proxy(peer)
                        task  = peer.local_object(self.task)
                        event = task.event(symbol)
                        if emitted && !event.emitted?
                            event.instance_eval { @emitted = true }
                        end
                        event
                    end
                end
            end

            module DelayedArgumentFromObjectDumper
                def droby_dump(peer)
                    DRoby.new(
                        peer.dump(self.class),
                        peer.dump(@object),
                        @methods,
                        @weak)
                end

                class DRoby
                    def initialize(klass, object, methods, weak)
                        @klass, @object, @methods, @weak = klass, object, methods, weak
                    end
                    def proxy(peer)
                        base = peer.local_object(@klass).new(peer.local_object(@object), @weak)
                        @methods.inject(base) do |delayed_arg, m|
                            delayed_arg.send(m)
                        end
                    end
                end      
            end

            module TaskArgumentsDumper
                class DRoby
                    attr_reader :values
                    def initialize(values)
                        @values = values
                    end

                    def proxy(peer)
                        obj = TaskArguments.new(nil)
                        obj.values.merge!(peer.local_object(values))
                        obj
                    end
                end

                def droby_dump(peer)
                    DRoby.new(peer.dump(values))
                end
            end

            module TaskDumper
                # Returns an intermediate representation of +self+ suitable to be sent
                # to the +dest+ peer.
                def droby_dump(peer)
                    arguments = Hash.new
                    model.arguments.each do |arg_name|
                        if self.arguments.assigned?(arg_name)
                            arguments[arg_name] = self.arguments.raw_get(arg_name)
                        end
                    end

                    DRoby.new(peer.known_siblings_for(self),
                              peer.dump(owners),
                              peer.dump(model),
                              plan.droby_id, 
                              peer.dump(arguments),
                              peer.dump(data),
                              mission: mission?, started: started?,
                              finished: finished?, success: success?)
                end

                # An intermediate representation of Task objects suitable
                # to be sent to our peers.
                class DRoby < PlanObjectDumper::DRoby
                    # The set of dRoby-formatted arguments
                    attr_reader :arguments
                    # The task's internal data
                    attr_reader :data
                    # A set of boolean flags which describe the task's status. It is a
                    # symbol => bool flag where the following parameters are save:
                    # started:: if the task has started
                    # finished:: if the task has finished
                    # success:: if the task has finished with success
                    # mission:: if the task is a mission in its plan
                    attr_reader :flags

                    # Create a new DRoby object with the given information
                    def initialize(remote_siblings, owners, model, plan_id, arguments, data, **flags)
                        super(remote_siblings, owners, model, plan_id)
                        @arguments, @data, @flags = arguments, data, flags
                    end

                    # Create a new proxy which maps the object of +peer+ represented by
                    # this communication intermediate.
                    def proxy(peer)
                        arguments = peer.local_object(self.arguments)
                        peer.local_object(model).new(arguments.merge(plan: peer.local_plan(plan_id)))
                    end

                    # Updates an already existing proxy using the information contained
                    # in this object.
                    def update(peer, task, fresh_proxy: false)
                        super

                        task.started  = flags[:started]
                        task.finished = flags[:finished]
                        task.success  = flags[:success]

                        if task.mission? != flags[:mission]
                            if flags[:mission]
                                task.plan.add_mission_task(task)
                            else
                                task.plan.unmark_mission_task(task)
                            end
                        end

                        if !fresh_proxy
                            task.arguments.merge!(peer.local_object(arguments))
                        end
                        task.instance_variable_set("@data", peer.local_object(data))
                    end
                end
            end

            module PlanDumper
                def droby_dump(peer)
                    peer.dump_groups(tasks, task_events, free_events) do |tasks, task_events, free_events|
                        mission_tasks = peer.dump(self.mission_tasks)
                        permanent_tasks  = peer.dump(self.permanent_tasks)
                        permanent_events = peer.dump(self.permanent_events)
                        task_relation_graphs = each_task_relation_graph.map do |g|
                            edges = peer.dump(g.each_edge.flat_map { |*args| args })
                            [peer.dump(g.class), edges]
                        end
                        event_relation_graphs = each_event_relation_graph.map do |g|
                            edges = peer.dump(g.each_edge.flat_map { |*args| args })
                            [peer.dump(g.class), edges]
                        end

                        DRoby.new(
                            DRobyConstant.new(self.class), droby_id,
                            tasks, task_events, free_events,
                            mission_tasks, permanent_tasks, permanent_events,
                            task_relation_graphs, event_relation_graphs)
                    end
                end

                class DRoby
                    attr_reader :plan_class
                    attr_reader :droby_id
                    attr_reader :groups
                    attr_reader :tasks
                    attr_reader :task_events
                    attr_reader :free_events
                    attr_reader :mission_tasks
                    attr_reader :permanent_tasks
                    attr_reader :permanent_events
                    attr_reader :task_relation_graphs
                    attr_reader :event_relation_graphs

                    def initialize(plan_class, droby_id,
                                   tasks, task_events, free_events,
                                   mission_tasks, permanent_tasks, permanent_events,
                                   task_relation_graphs, event_relation_graphs)
                        @plan_class            = plan_class
                        @droby_id              = droby_id
                        @tasks           = tasks
                        @task_events           = task_events
                        @free_events           = free_events
                        @mission_tasks         = mission_tasks
                        @permanent_tasks       = permanent_tasks
                        @permanent_events      = permanent_events
                        @task_relation_graphs  = task_relation_graphs
                        @event_relation_graphs = event_relation_graphs
                    end

                    def proxy(peer)
                        plan = Plan.new
                        peer.with_object(droby_id => plan) do
                            peer.load_groups(tasks, task_events, free_events) do |tasks, task_events, free_events|
                                plan.tasks.merge(tasks)
                                plan.task_events.merge(task_events)
                                plan.free_events.merge(free_events)

                                plan.mission_tasks.replace(peer.local_object(mission_tasks))
                                plan.permanent_tasks.replace(peer.local_object(permanent_tasks))
                                plan.permanent_events.replace(peer.local_object(permanent_events))

                                task_relation_graphs.each do |rel_id, edges|
                                    rel = peer.local_object(rel_id)
                                    g   = plan.task_relation_graph_for(rel)
                                    peer.local_object(edges).each_slice(3) do |from, to, info|
                                        g.add_edge(from, to, info)
                                    end
                                end
                                event_relation_graphs.each do |rel_id, edges|
                                    rel = peer.local_object(rel_id)
                                    g   = plan.event_relation_graph_for(rel)
                                    peer.local_object(edges).each_slice(3) do |from, to, info|
                                        g.add_edge(from, to, info)
                                    end
                                end
                            end
                        end
                        plan
                    end
                end
            end

            module Actions
                module ActionDumper
                    def droby_dump(peer)
                        result = dup
                        result.droby_dump!(peer)
                        result
                    end

                    def droby_dump!(peer)
                        @model = peer.dump(model)
                        @arguments = peer.dump(arguments)
                    end

                    def proxy(peer)
                        result = dup
                        result.proxy!(peer)
                        result
                    end

                    def proxy!(peer)
                        @model = peer.local_object(model)
                        @arguments = peer.local_object(arguments)
                    end
                end

                module Models
                    module ActionDumper
                        def droby_dump(dest)
                            dump = self.dup
                            dump.droby_dump!(dest)
                            dump
                        end

                        def droby_dump!(peer)
                            @action_interface_model = peer.dump(action_interface_model)
                            @returned_type = peer.dump(returned_type)
                            @arguments = peer.dump(arguments)
                            @coordination_model = nil
                            @returned_task_type = nil
                        end
                    end

                    class Action
                        module ArgumentDumper
                            def droby_dump(peer)
                                result = self.dup
                                result.droby_dump!(peer)
                                result
                            end

                            def droby_dump!(peer)
                                self.default = peer.dump(default)
                            end

                            def proxy(peer)
                                result = dup
                                result.proxy!(peer)
                                result
                            end

                            def proxy!(peer)
                                self.default = peer.local_object(default)
                            end
                        end
                    end
                end
            end

            module Queries
                module AndMatcherDumper
                    # An intermediate representation of AndMatcher objects suitable to
                    # be sent to our peers.
                    class DRoby
                        attr_reader :ops
                        def initialize(ops)
                            @ops = ops
                        end
                        def proxy(peer)
                            Roby::Queries::AndMatcher.new(*peer.local_object(ops))
                        end
                    end
                    
                    # Returns an intermediate representation of +self+ suitable to be sent
                    # to the +dest+ peer.
                    def droby_dump(peer)
                        DRoby.new(peer.dump(@ops))
                    end
                end

                module NotMatcherDumper
                    # An intermediate representation of NegateTaskMatcher objects suitable to
                    # be sent to our peers.
                    class DRoby
                        def initialize(op)
                            @op = op
                        end
                        def proxy(peer)
                            Roby::Queries::NotMatcher.new(peer.local_object(@op))
                        end
                    end
                    
                    # Returns an intermediate representation of +self+ suitable to be sent
                    # to the +dest+ peer.
                    def droby_dump(peer)
                        DRoby.new(peer.dump(@op))
                    end
                end

                module OrMatcherDumper
                    # An intermediate representation of OrMatcher objects suitable to
                    # be sent to our peers.
                    class DRoby
                        attr_reader :ops
                        def initialize(ops)
                            @ops = ops
                        end
                        def proxy(peer)
                            Roby::Queries::OrMatcher.new(*peer.local_object(ops))
                        end
                    end
                    
                    # Returns an intermediate representation of +self+ suitable to be sent
                    # to the +dest+ peer.
                    def droby_dump(dest)
                        DRoby.new(dest.dump(@ops))
                    end
                end

                module ExecutionExceptionMatcherDumper
                    # An intermediate representation of ExecutionExceptionMatcher objects suitable to
                    # be sent to our peers.
                    class DRoby
                        attr_reader :exception_matcher, :involved_tasks_matchers
                        def initialize(exception_matchers, involved_tasks_matchers)
                            @exception_matcher = exception_matcher
                            @involved_tasks_matchers = involved_tasks_matchers
                        end
                        def proxy(peer)
                            matcher = Roby::Queries::ExecutionExceptionMatcher.new
                            matcher.with_exception(peer.local_object(exception_matcher))
                            involved_tasks_matchers.each do |m|
                                matcher.involving(peer.local_object(m))
                            end
                            matcher
                        end
                    end
                    
                    # Returns an intermediate representation of +self+ suitable to be sent
                    # to the +dest+ peer.
                    def droby_dump(peer)
                        DRoby.new(
                            peer.dump(exception_matcher),
                            peer.dump(involved_tasks_matchers))
                    end
                end

                module LocalizedErrorMatcherDumper
                    # An intermediate representation of OrMatcher objects suitable to
                    # be sent to our peers.
                    class DRoby
                        attr_reader :model, :failure_point_matcher
                        def initialize(model, failure_point_matcher)
                            @model = model
                            @failure_point_matcher = failure_point_matcher
                        end
                        def proxy(peer)
                            matcher = Roby::Queries::LocalizedErrorMatcher.new
                            matcher.with_model(peer.local_object(model))
                            matcher.with_origin(peer.local_object(failure_point_matcher))
                            matcher
                        end
                    end
                    
                    # Returns an intermediate representation of +self+ suitable to be sent
                    # to the +dest+ peer.
                    def droby_dump(peer)
                        DRoby.new(
                            peer.dump(model),
                            peer.dump(failure_point_matcher))
                    end
                end

                module PlanObjectMatcherDumper
                    # An intermediate representation of TaskMatcher objects suitable to be
                    # sent to our peers.
                    class DRoby
                        # The exact match class that has been marshalled using this object
                        attr_reader :model
                        attr_reader :predicates
                        attr_reader :neg_predicates
                        attr_reader :indexed_predicates
                        attr_reader :indexed_neg_predicates
                        attr_reader :parents
                        attr_reader :children
                        attr_reader :owners

                        def initialize(model, predicates, neg_predicates, indexed_predicates, indexed_neg_predicates, owners, parents, children)
                            @model = model
                            @predicates, @neg_predicates, @indexed_predicates, @indexed_neg_predicates =
                                predicates, neg_predicates, indexed_predicates, indexed_neg_predicates
                            @owners = owners
                            @parents = parents
                            @children = children
                        end

                        # Common initialization of a TaskMatcher object from the given
                        # argument set. This is to be used by DRoby-dumped versions of
                        # subclasses of TaskMatcher.
                        def proxy(peer, matcher: Roby::Queries::PlanObjectMatcher.new)
                            model  = peer.local_object(self.model)
                            owners = peer.local_object(self.owners)

                            matcher.with_model(model)
                            matcher.predicates.merge(predicates)
                            matcher.neg_predicates.merge(neg_predicates)
                            matcher.indexed_predicates.merge(indexed_predicates)
                            matcher.indexed_neg_predicates.merge(indexed_neg_predicates)
                            matcher.parents.merge!(peer.local_object(parents))
                            matcher.children.merge!(peer.local_object(children))
                            matcher.owners.concat(owners)
                            matcher
                        end
                    end

                    # Returns an intermediate representation of +self+ suitable to be sent
                    # to the +dest+ peer. +klass+ is the actual class of the intermediate
                    # representation. It is used for code reuse by subclasses of
                    # TaskMatcher.
                    def droby_dump(peer, droby: DRoby)
                        droby.new(peer.dump(model),
                                  predicates, neg_predicates, indexed_predicates, indexed_neg_predicates,
                                  peer.dump(owners),
                                  peer.dump(parents), peer.dump(children))
                    end
                end

                module TaskMatcherDumper
                    # An intermediate representation of TaskMatcher objects suitable to be
                    # sent to our peers.
                    class DRoby < PlanObjectMatcherDumper::DRoby
                        attr_reader :arguments

                        def initialize(*args)
                            @arguments = Hash.new
                            super(*args)
                        end

                        def proxy(peer, matcher: Roby::Queries::TaskMatcher.new)
                            super(peer, matcher: matcher)
                            matcher.arguments.merge!(arguments.proxy(peer))
                            matcher
                        end
                    end

                    # Returns an intermediate representation of +self+ suitable to be sent
                    # to the +dest+ peer. +klass+ is the actual class of the intermediate
                    # representation. It is used for code reuse by subclasses of
                    # TaskMatcher.
                    def droby_dump(peer, droby: DRoby)
                        droby = super(peer, droby: droby)
                        droby.arguments.merge!(peer.dump(arguments))
                        droby
                    end
                end

                module QueryDumper
                    # An intermediate representation of Query objects suitable to be sent
                    # to our peers.
                    class DRoby < TaskMatcherDumper::DRoby
                        attr_accessor :plan_id
                        attr_accessor :scope
                        attr_reader :plan_predicates, :neg_plan_predicates
                        def initialize(*args)
                            super
                            @plan_predicates, @neg_plan_predicates = Set.new, Set.new
                        end

                        def proxy(peer)
                            query = peer.local_plan(plan_id).find_tasks
                            super(peer, matcher: query)
                            query.plan_predicates.merge(plan_predicates)
                            query.neg_plan_predicates.merge(neg_plan_predicates)
                            if scope == :local
                                query.local_scope
                            else query.global_scope
                            end
                            query
                        end
                    end
                    
                    # Returns an intermediate representation of +self+ suitable to be sent
                    # to the +dest+ peer.
                    def droby_dump(peer)
                        droby = super(peer, droby: DRoby)
                        droby.plan_id = plan.droby_id
                        droby.scope = scope
                        droby.plan_predicates.merge(plan_predicates)
                        droby.neg_plan_predicates.merge(neg_plan_predicates)
                        droby
                    end
                end
            end
        end
    end
end
