module RESTRack

  # All RESTRack controllers should descend from ResourceController.  This class
  # provides the methods for your controllers.
  #
  #                    HTTP Verb: |    GET    |   PUT     |   POST    |   DELETE
  # Collection URI (/widgets/):   |   index   |   replace |   create  |   drop
  # Element URI   (/widgets/42):  |   show    |   update  |   add     |   destroy
  #

  class ResourceController
    attr_reader :action, :id, :params
    class << self; attr_accessor :key_type; end

    # Base initialization method for resources and storage of request input
    # This method should not be overriden in decendent classes.
    def self.__init(resource_request)
      __self = self.new
      return __self.__init(resource_request)
    end
    def __init(resource_request)
      @resource_request = resource_request
      @request = @resource_request.request
      @params = @resource_request.params
      @post_params = @resource_request.post_params
      @get_params = @resource_request.get_params
      self
    end

    # Call the controller's action and return output in the proper format.
    def call
      self.determine_action
      args = []
      args << @id unless @id.blank?
      unless self.respond_to?(@action.to_sym) or self.respond_to?(:method_missing)
        raise HTTP405MethodNotAllowed, 'Method not provided on controller.'
      end
      self.send(@action.to_sym, *args)
    end

    # all internal methods are protected rather than private so that calling methods *could* be overriden if necessary.
    protected

    # If called with an array of strings this will return a datastructure which will
    # automatically be converted by RESTRack into the error format expected by ActiveResource.
    # ActiveResource expects attribute input errors to be responded to with a status
    # code of 422, which is a non-standard HTTP code.  Use this to produce the required
    # format of "<errors><error>...</error><error>...</error></errors>" for the response XML.
    # This method also will accept any simple data structure when not worried about AR integration.
    def package_errors(errors)
      if errors.is_a? Array and errors.count{|e| e.is_a? String} === errors.length
        # I am AR bound
        errors = ARFormattedError.new(errors)
      end
      @output = @resource_request.package(errors)
      @output
    end

    def package_error(error)
      errors = error.is_a?(String) ? [error] : error
      package_errors(errors)
    end

    # This method allows one to access a related resource, without providing a direct link to specific relation(s).
    def self.pass_through_to(entity, opts = {})
      entity_name = opts[:as] || entity
      define_method( entity_name.to_sym,
        Proc.new do |calling_id| # The calling resource's id will come along for the ride when the new bridging method is called magically from ResourceController#call
          @resource_request.call_controller(entity)
        end
      )
    end

    # This method defines that there is a single link to a member from an entity collection.
    # The second parameter is an options hash to support setting the local name of the relation via ':as => :foo'.
    # The third parameter to the method is a Proc which accepts the calling entity's id and returns the id of the relation to which we're establishing the link.
    # This adds an accessor instance method whose name is the entity's class.
    def self.has_relationship_to(entity, opts = {}, &get_entity_id_from_relation_id)
      entity_name = opts[:as] || entity
      define_method( entity_name.to_sym,
        Proc.new do |calling_id| # The calling resource's id will come along for the ride when the new bridging method is called magically from ResourceController#call
          id = get_entity_id_from_relation_id.call(@id)
          @resource_request.url_chain.unshift(id)
          @resource_request.call_controller(entity)
        end
      )
    end

    # This method defines that there are multiple links to members from an entity collection (an array of entity identifiers).
    # This adds an accessor instance method whose name is the entity's class.
    def self.has_relationships_to(entity, opts = {}, &get_entity_id_from_relation_id)
      entity_name = opts[:as] || entity
      define_method( entity_name.to_sym,
        Proc.new do |calling_id| # The parent resource's id will come along for the ride when the new bridging method is called magically from ResourceController#call
          entity_array = get_entity_id_from_relation_id.call(@id)
          begin
            index = @resource_request.url_chain.shift.to_i
          rescue
            raise HTTP400BadRequest, 'You requested an item by index and the index was not a valid number.'
          end
          unless index < entity_array.length
            raise HTTP404ResourceNotFound, 'You requested an item by index and the index was larger than this item\'s list of relations\' length.'
          end
          id = entity_array[index]
          @resource_request.url_chain.unshift(id)
          @resource_request.call_controller(entity)
        end
      )
    end

    # This method defines that there are multiple links to members from an entity collection (an array of entity identifiers).
    # This adds an accessor instance method whose name is the entity's class.
    def self.has_defined_relationships_to(entity, opts = {}, &get_entity_id_from_relation_id)
      entity_name = opts[:as] || entity
      define_method( entity_name.to_sym,
        Proc.new do |calling_id| # The parent resource's id will come along for the ride when the new bridging method is called magically from ResourceController#call
          entity_array = get_entity_id_from_relation_id.call(@id)
          id = @resource_request.url_chain.shift
          raise HTTP400BadRequest, 'No ID provided for has_defined_relationships_to routing.' if id.nil?
          id = RESTRack.controller_class_for(entity).format_string_id(id) if id.is_a? String
          unless entity_array.include?( id )
            raise HTTP404ResourceNotFound, 'Relation entity does not belong to referring resource.'
          end
          @resource_request.url_chain.unshift(id)
          @resource_request.call_controller(entity)
        end
      )
    end

    # This method defines that there are mapped links to members from an entity collection (a hash of entity identifiers).
    # This adds an accessor instance method whose name is the entity's class.
    def self.has_mapped_relationships_to(entity, opts = {}, &get_entity_id_from_relation_id)
      entity_name = opts[:as] || entity
      define_method( entity_name.to_sym,
        Proc.new do |calling_id| # The parent resource's id will come along for the ride when the new bridging method is called magically from ResourceController#call
          entity_map = get_entity_id_from_relation_id.call(@id)
          key = @resource_request.url_chain.shift
          id = entity_map[key.to_sym]
          @resource_request.url_chain.unshift(id)
          @resource_request.call_controller(entity)
        end
      )
    end

    # Allows decendent controllers to set a data type for the id other than the default.
    def self.keyed_with_type(klass)
      self.key_type = klass
    end

    # Find the action, and id if relevant, that the controller must call.
    def determine_action
      term = @resource_request.url_chain.shift
      if term.nil?
        @id = nil
        @action = nil
      # id terms can be pushed on the url_stack which are not of type String by relationship handlers
      elsif term.is_a? String and self.methods.include?( term.to_sym )
        @id = self.methods.include?(@resource_request.url_chain[0]) ? nil : @resource_request.url_chain.shift
        @action = term.to_sym
      else
        begin
          self.class.format_string_id(term)
        rescue
          # if this isn't a valid id then it must be a request for an action that doesn't exist (we tested it as an action name above)
          raise HTTP405MethodNotAllowed, 'Action not provided or found and unknown HTTP request method.'
        end
        @id = term
        term = @resource_request.url_chain.shift
        if term.nil?
          @action = nil
        elsif self.methods.include?( term.to_sym )
          @action = term.to_sym
        else
          raise HTTP405MethodNotAllowed, 'Action not provided or found and unknown HTTP request method.'
        end
      end
      @id = self.class.format_string_id(@id) if @id.is_a? String
      # If the action is not set with the request URI, determine the action from HTTP Verb.
      get_action_from_context if @action.blank?
    end

    # This method is used to convert the id coming off of the path stack, which is in string form, into another data type if one has been set.
    def self.format_string_id(id)
      return nil unless id
      # default key type of resources is String
      self.key_type ||= String
      unless self.key_type.blank? or self.key_type.ancestors.include?(String)
        if self.key_type.ancestors.include?(Integer)
          id = Integer(id)
        elsif self.key_type.ancestors.include?(Float)
          id = Float(id)
        else
          raise HTTP500ServerError, "Invalid key identifier type specified on resource #{self.class.to_s}."
        end
      end
      id
    end

    # Get action from HTTP verb
    def get_action_from_context
      if @resource_request.request.get?
        @action = @id.blank? ? :index   : :show
      elsif @resource_request.request.put?
        @action = @id.blank? ? :replace : :update
      elsif @resource_request.request.post?
        @action = @id.blank? ? :create  : :add
      elsif @resource_request.request.delete?
        @action = @id.blank? ? :drop    : :destroy
      else
        raise HTTP405MethodNotAllowed, 'Action not provided or found and unknown HTTP request method.'
      end
    end

  end # class ResourceController
end # module RESTRack
