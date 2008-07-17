module Zena
  module Relations
    module HasRelations
      # this is called when the module is included into the 'base' module
      def self.included(base)
        # add all methods from the module "AddActsAsMethod" to the 'base' module
        base.extend Zena::Relations::ClassMethods
      end
    end
    
    module ClassMethods
      def has_relations
        validate      :relations_valid
        after_save    :update_relations
        after_destroy :destroy_links
        
        class_eval <<-END
        include Zena::Relations::InstanceMethods
          def relation_base_class
            #{self}
          end
        END
      end
    end
    
    
    module InstanceMethods
      private
      
        # Used to create / destroy / update links through pseudo methods 'icon_id=', 'icon_status=', ...
        # Pseudo methods created for a many-to-one relation (icon_for --- icon):
        # icon_id=::      set icon
        # icon_status=::  set status field for link to icon
        # icon_comment=:: set comment field for link to icon
        # icon_for_ids=:: set all nodes for which the image is an icon (replaces old values)
        # icon_for_id=::  add a node for which the image is an icon (adds a new value)
        # icon_id::       get icon id
        # icon_zip::      get icon zip
        # icon_status::   get status field for link to icon
        # icon_comment::  get comment field for link to icon
        # icon_for_ids::  get all node ids for which the image is an icon
        # icon_for_zips:: get all node zips for which the image is an icon
        def method_missing(meth, *args)
          # first try rails' version of method missing
          super
        rescue NoMethodError => err
          # 1. is this a method related to a relation ?
          if meth.to_s =~ /^([\w_]+)_(ids?|zips?|status|comment)(=?)$/
            role  = $1
            field = $2
            mode  = $3
            # 2. is this a valid role ?
            if rel = get_relation_proxy(role)
              if mode == '='
                # set
                case field
                when 'zip', 'zips'
                  # not used to set relations (must use 'translate_attributes' to chagen zip into id before call)
                  raise err
                when 'id', 'ids', 'zip', 'zips'
                  if field[-1..-1] == 's'
                    # plural
                    raise err if rel.unique?
                  else
                    # singular
                    raise err if !rel.unique?
                  end
                else
                  # comment, status: must be singular
                  raise err if !rel.unique?
                end
                # set value
                rel.send("other_#{field}=", args[0])
              else
                # get
                case field
                when 'id', 'ids'
                  if field[-1..-1] == 's'
                    # plural
                    raise err if rel.unique?
                  else
                    # singular
                    raise err if !rel.unique?
                  end
                else
                  # comment, status: must be singular
                  raise err if !rel.unique?
                end
                rel.send("other_#{field}")
              end
            else
              # invalid relation
              raise err
            end
          else
            # not related to relations
            raise err
          end
        end
      
        def get_relation_proxy(role)
          @relation_proxies ||= {}
          return @relation_proxies[role] if defined?(@relation_proxies[role])
          rel = Relation.find_by_role_and_kpath(role.singularize.underscore, self.vclass.kpath)
          if rel
            rel.start = self
          end
          @relation_proxies[role] = rel
        end
      
        # Make sure all updated relation proxies are valid
        def relations_valid
          return true unless @relation_proxies
          @relation_proxies.each do |rel|
            unless rel.attributes_to_update_valid?
              errors.add(role, rel.link_errors.join(', '))
            end
          end
        end
        
        # Update/create links defined in relation proxies
        def update_relations
          return unless @relation_proxies
          @relation_proxies.each do |rel|
            rel.update_links!
          end
        end
        
        # Destroy all links related to this node
        def destroy_links
          Link.find(:all, :conditions => ["source_id = ? OR target_id = ?", self[:id], self[:id]]).each do |l|
            l.destroy
          end
        end
    end
  end
end

ActiveRecord::Base.send :include, Zena::Relations::HasRelations

=begin
module Zena
  module Relations
    def self.plural_method?(method)
      m = method.split('_').first
      m.pluralize == m || method.ends_with?('_for')
    end
  
    module HasRelations
      # this is called when the module is included into the 'base' module
      def self.included(base)
        # add all methods from the module "AddActsAsMethod" to the 'base' module
        base.extend Zena::Relations::ClassMethods
      end
    end
    
    module ClassMethods
      def has_relations(opts={})
        opts[:class] ||= self
        validate      :valid_links
        after_save    :update_links
        after_destroy :destroy_links
        
        class_eval <<-END
        include Zena::Relations::InstanceMethods
          def relation_base_class
            #{opts[:class]}
          end
        END
      end
      
      def split_kpath
        @split_kpath ||= begin
          klasses   = []
          kpath.split(//).each_index { |i| klasses << kpath[0..i] } 
          klasses
        end
      end
      
      def find_relation(opts)
        role_name = (opts[:role] || '').singularize
        if opts[:id]
          if opts[:source]
            conditions = ["site_id = ? AND id = ? AND source_kpath IN (?)", current_site[:id], opts[:id], split_kpath]
          else
            conditions = ["site_id = ? AND id = ? AND target_kpath IN (?)", current_site[:id], opts[:id], split_kpath]
          end
        else
          if opts[:from] || opts[:ignore_source]
            conditions = ["site_id = ? AND (target_role = ? OR source_role = ?)", current_site[:id], role_name, role_name]
          else
            conditions = ["site_id = ? AND ((target_role = ? AND source_kpath IN (?)) OR (source_role = ? AND target_kpath IN (?)))", current_site[:id], role_name, split_kpath, role_name, split_kpath]
          end
        end
        relation = Relation.find(:first, :conditions => conditions)
        return nil unless relation
        if opts[:start]
          if relation.target_role == role_name
            relation.source = opts[:start]
          else
            relation.target = opts[:start]
          end
        elsif opts[:source]
          relation.source = opts[:source]
        else
          relation.target = opts[:target]
        end
        relation
      end
      
      def all_relations(start=nil)
        rel_as_source = Relation.find(:all, :conditions => ["site_id = ? AND source_kpath IN (?)", current_site[:id], split_kpath])
        rel_as_target = Relation.find(:all, :conditions => ["site_id = ? AND target_kpath IN (?)", current_site[:id], split_kpath])
        rel_as_source.each {|rel| rel.source = start } if start
        rel_as_target.each {|rel| rel.target = start } if start
        (rel_as_source + rel_as_target).sort {|a,b| a.other_role <=> b.other_role}
      end
    end
    
    
    module InstanceMethods
      
      # set can be a list:
      # * [12,23,45]
      # or elements, one by one
      # * :status => 4
      # * :comment => 'tada'
      # * :id => 34
      def set_relation(role, value)
        if value.kind_of?(Array)
          @relations_to_update ||= []
          @relations_to_update << [:set, [role, value]]
        else
          @set_relations ||= {}
          if @set_relations[role]
            @set_relations[role].merge!(value)
          else
            @set_relations[role] = value.dup
            @relations_to_update ||= []
            @relations_to_update << [:set, [role, @set_relations[role]]]
          end
        end
      end
      
      alias update_link set_relation
      
      def remove_link(link_id)
        @relations_to_update ||= []
        @relations_to_update << [:remove, link_id]
      end
      
      def add_link(role, value)
        @relations_to_update ||= []
        @relations_to_update << [:add, [role, value]]
      end
      
      def all_relations
        @all_relations ||= self.vclass.all_relations(self)
      end

      def relations_for_form
        all_relations.map {|r| [r.other_role.singularize, r.other_role]}
      end
      
      # List the links, grouped by role
      def relation_links
        res = []
        all_relations.each do |relation|
          #if relation.record_count > 5
          #  # FIXME: show message ?
          #end
          links = relation.records(:limit => 5, :order => "link_id DESC")
          res << [relation, links] if links
        end
        res
      end
      
      
      # Proxy to access user defined relations. The proxy is used to create/update links using the relation.
      #
      # Usage: node.relation_proxy(:role => 'news')
      def relation_proxy(opts={})
        opts = {:role => opts} unless opts.kind_of?(Hash)
        if role = opts[:role]
          if opts[:ignore_source]
            rel = Relation.find_by_role(role.singularize.underscore)
          else
            rel = Relation.find_by_role_and_kpath(role.singularize.underscore, self.vclass.kpath)
          end
          rel.start = self if rel
        elsif link = opts[:link]
          return nil unless link
          rel = Relation.find_by_id(link.relation_id)
          if rel
            rel.link = link
            rel.start = self
            if link.source_id == self[:id]
              rel.side = :source
            else
              rel.side = :target
            end
          end
        end
        rel
      end
      
      # status defined through loading link
      def l_status
        val = @link ? @link[:status] : self['l_status']
        val ? val.to_i : nil
      end
      
      # comment defined through loading link
      def l_comment
        @link ? @link[:comment] : self['l_comment']
      end
      
      # ALL THIS IS HORRIBLE CODE. NEED MORE TIME TO REWRITE THIS BIG MESS...
      def l_status=(v)
        self[:l_status] = v
        @link_to_update ||= {}
        @link_to_update[:status] = v
      end
      
      def l_comment=(v)
        self[:l_comment] = v
        @link_to_update ||= {}
        @link_to_update[:comment] = v
      end
      
      def link_id
        @link ? @link[:id] : self[:link_id]
      end
      
      def link_id=(v)
        if @link && @link[:id].to_i != v.to_i
          @link = nil
        end
        self[:link_id] = v.to_i
        @link_to_update ||= {}
        @link_to_update[:id] = v.to_i
      end
      
      private
        # ANOTHER HACK...
        def valid_update_link
          return true unless @link_to_update
          if self.link_id.blank?
            errors.add('link', 'id not set')
            return false
          end
          return true if !@link_to_update[:comment] && !@link_to_update[:status]
          
          unless @link && @link[:id] == @link_to_update[:id]
            @link = Link.find_through(self, self.link_id)
            unless @link
              errors.add('link', 'not found')
              return false
            end
          end
          return true
        end
        
        def valid_links
          valid_update_link
          return true unless @relations_to_update
          @valid_relations_to_update = []
          @relations_to_update.each do |action, params|
            case action
            when :set
              role, value = params
              if relation = relation_proxy(:role => role)
                relation.new_value = value
                if relation.links_valid?
                  @valid_relations_to_update << relation
                else
                  errors.add(role, relation.link_errors.join(', '))
                end
              else
                errors.add(role, 'undefined relation')
              end
            when :add
              role, value = params
              if relation = relation_proxy(:role => role)
                relation << value
                if relation.links_valid?
                  @valid_relations_to_update << relation
                else
                  errors.add(role, relation.link_errors.join(', '))
                end
              else
                errors.add(role, 'undefined relation')
              end
            when :remove
              link_id = params
              link = Link.find(:first, :conditions => ['(source_id = ? OR target_id = ?) AND id = ?', self[:id], self[:id], link_id])
              if relation = relation_proxy(:link => link)
                if link['source_id'] == self[:id]
                  relation.delete(link['target_id'])
                else
                  relation.delete(link['source_id'])
                end
                if relation.links_valid?
                  @valid_relations_to_update << relation
                else
                  errors.add(role, relation.link_errors.join(', '))
                end
              else
                errors.add('base', 'unknown link')
              end
            end
          end
        
        end
      
        def update_links
          if @link_to_update && @link
            [:comment, :status].each do |k|
              next unless defined?(@link_to_update[k])
              @link[k] = @link_to_update[k]
            end
            @link.save
          end
          
          return if @valid_relations_to_update.blank?
          @valid_relations_to_update.each do |relation|
            relation.update_links!
          end
          remove_instance_variable(:@valid_relations_to_update)
          remove_instance_variable(:@relations_to_update)
        end
        
        def destroy_links
          Link.find(:all, :conditions => ["source_id = ? OR target_id = ?", self[:id], self[:id]]).each do |l|
            l.destroy
          end
        end
        
        # shortcut accessors like tags_id = ...
        def method_missing(meth, *args)
          super
        rescue NoMethodError => err
          if meth.to_s =~ /^([\w_]+)_(id|zip|status|comment)(s?)(=?)$/
            role  = $1
            field = $2
            plural = $3
            mode  = $4
            if rel = relation_proxy(:role => role, :ignore_source => true)
              if self.vclass.kpath =~ /\A#{rel.this_kpath}/
                if mode == '='
                  super if field == 'zip'
                  # add_link
                  value = args[0]
                  if value.kind_of?(Array)
                    if field != 'id'
                      # ignore, cannot set multiple link status,comment through this interface.
                      # tag_comments = ['lala', 'loulou', 'lili'] does not make sense.
                      return
                    end
                    # many
                    set_relation(role,value)
                  else
                    add_link(role,value)
                  end
                else
                  # get ids / zips
                  rel.send("other_#{field}#{plural}")
                end
              elsif mode == '='
                # bad relation for this class of object
                errors.add(role, "invalid for this class")
              else
                # ignore
                nil
              end
            else
              # unknown relation
              errors.add(role, "unknown relation")
            end
          else
            raise err # unknown relation
          end
        end
    end
  end
end

ActiveRecord::Base.send :include, Zena::Relations::HasRelations
=end