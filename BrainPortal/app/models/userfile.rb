
#
# CBRAIN Project
#
# Userfile model
#
# Original author: Tarek Sherif (based on the original by P. Rioux)
#
# $Id$
#

require 'set'

#Abstract model representing files actually registered to the system.
#
#<b>Userfile should not be instantiated directly.</b> Instead, all files
#should be registered through one of the subclasses (SingleFile, FileCollection
#or CivetCollection as of this writing).
#
#=Attributes:
#[*name*] The name of the file.
#[*size*] The size of the file.
#[*task*] The CbrainTask (if any) that produced this file.
#=Acts as:
#[*nested_set*] The nested set module allows for the creation of
#               a tree structure of userfiles. Userfiles created
#               as the output of some processing on a given userfile
#               will be considered children of that userfile.
#= Associations:
#*Belongs* *to*:
#* User
#* DataProvider
#* Group
#*Has* *and* *belongs* *to* *many*:
#* Tag
class Userfile < ActiveRecord::Base

  Revision_info="$Id$"
  Default_num_pages = "50"

  belongs_to              :user
  belongs_to              :data_provider
  belongs_to              :group
  belongs_to              :format_source,
                          :class_name   => "Userfile",
                          :foreign_key  => "format_source_id"
  belongs_to              :parent,
                          :class_name   => "Userfile",
                          :foreign_key  => "parent_id"
                          
  has_and_belongs_to_many :tags
  has_many                :sync_status
  has_many                :formats,
                          :class_name   => "Userfile",
                          :foreign_key  => "format_source_id"
  has_many                :children,
                          :class_name   => "Userfile",
                          :foreign_key  => "parent_id"
                                                    
  validates_uniqueness_of :name, :scope => [ :user_id, :data_provider_id ]
  validates_presence_of   :name
  validates_presence_of   :user_id
  validates_presence_of   :data_provider_id
  validates_presence_of   :group_id
  validate                :validate_associations
  validate                :validate_filename
  
  before_destroy          :erase_or_unregister, :format_tree_update, :nullify_children
  
  attr_accessor           :level
  attr_accessor           :tree_children

  class Viewer
    attr_reader :name, :partial
    
    def initialize(viewer)
      atts = viewer
      unless atts.is_a? Hash
        atts = { :name  => viewer.to_s.underscore.titleize, :partial => viewer.to_s.underscore }
      end
      initialize_from_hash(atts)
    end
    
    def initialize_from_hash(atts = {})
      unless atts.has_key?(:name) || atts.has_key?(:partial)
        cb_error("Viewer must have either name or partial defined.")
      end
      
      name       = atts.delete(:name)
      partial    = atts.delete(:partial)
      att_if     = atts.delete(:if)      || []
      cb_error "Unknown viewer option: '#{atts.keys.first}'." unless atts.empty?

      @conditions = []
      @name       = name      || partial.to_s.clone
      @partial    = partial   || name.to_s.clone   
      att_if = [ att_if ] unless att_if.is_a?(Array)
      att_if.each do |method|
        cb_error "Invalid :if condition '#{method}' in model." unless method.respond_to?(:to_proc)
        @conditions << method.to_proc
      end
    end
    
    def valid_for?(userfile)
      return true if @conditions.empty?
      @conditions.all? { |condition| condition.call(userfile) }
    end
    
    def ==(other)
      return false unless other.is_a? Viewer
      self.name == other.name
    end
  end

  def viewers
    class_viewers = self.class.class_viewers
    
    @viewers = class_viewers.select { |v| v.valid_for?(self) }
  end
  
  def find_viewer(name)
    self.viewers.find{ |v| v.name == name}
  end

  def site
    @site ||= self.user.site
  end
  
  # Define sort orders that don't refer to actual columns in the table.
  def self.pseudo_sort_columns
    ["tree_sort"]
  end
  
  #File extension for this file (helps sometimes in building urls).
  def file_extension
    self.name.scan(/\.[^\.]+$/).last
  end
  
  #Classes this type of file can be converted to.
  #Essentially distinguishes between SingleFile subtypes and FileCollection subtypes.
  def self.valid_file_types
    return @valid_file_types if @valid_file_types
    
    base_class = self
    base_class = SingleFile if self <= SingleFile
    base_class = FileCollection if self <= FileCollection
    
    @valid_file_types = base_class.send(:subclasses).unshift(base_class).map(&:name)
  end
  
  #Instance version of the class method.
  def valid_file_types
    self.class.valid_file_types
  end
  
  #Checks validity according to valid_file_types.
  def is_valid_file_type?(type)
    self.valid_file_types.include? type
  end
  
  #Updates the class (type attribute) of this file if +type+ is 
  #valid according to valid_file_types.
  def update_file_type(type)
    if self.is_valid_file_type?(type)
      self.type = type
      self.save
    else
      false
    end
  end
  
  #Format size for display in the view.
  #Returns the size as "<tt>nnn bytes</tt>" or "<tt>nnn KB</tt>" or "<tt>nnn MB</tt>" or "<tt>nnn GB</tt>".
  def format_size
    if size.blank?
      "unknown"
    elsif size >= 1_000_000_000
      sprintf "%6.1f GB", size/(1_000_000_000 + 0.0)
    elsif size >=     1_000_000
      sprintf "%6.1f MB", size/(    1_000_000 + 0.0)
    elsif size >=         1_000
      sprintf "%6.1f KB", size/(        1_000 + 0.0)
    else
      sprintf "%d bytes", size
    end
  end
  
  def add_format(userfile)
    source_file = self.format_source || self
    source_file.formats << userfile
  end
  
  def format_name
    nil
  end
  
  def format_names
    source_file = self.format_source || self
    @format_names ||= source_file.formats.map(&:format_name).push(self.format_name).compact 
  end
  
  def has_format?(f)
    if self.get_format(f)
      true
    else
      false
    end
  end
  
  def get_format(f)
    return self if self.format_name.to_s.downcase == f.to_s.downcase || self.class.name == f
    
    self.formats.all.find { |fmt| fmt.format_name.to_s.downcase == f.to_s.downcase || fmt.class.name == f }
  end

  #Return an array of the tags associated with this file
  #by +user+.
  def get_tags_for_user(user)
    u = user
    unless u.is_a? User
      u = User.find(u)
    end

    self.tags.select{|t| (self.tag_ids & u.tag_ids).include? t.id}
  end

  #Set the tags associated with this file to those
  #in the +tags+ array (represented by Tag objects
  #or ids).
  def set_tags_for_user(user, tags)
    all_tags = self.tag_ids
    current_user_tags = self.tag_ids & user.tag_ids

    self.tag_ids = (all_tags - current_user_tags) + ((tags || []).collect(&:to_i) & user.tag_ids)
    self.save
  end


  # Sort a list of files in "tree order" where
  # parents are listed just before their children.
  # It also keeps the original list's ordering
  # at each level. The method will set the :level
  # pseudo attribute too, with 0 for the top level.
  def self.tree_sort(userfiles = [])
    top       = Userfile.new( :parent_id => -999_999_999 ) # Dummy, to collect top level
    userfiles = userfiles.to_a + [ top ] # Note: so that by_id[nil] returns 'top'
    by_id     = userfiles.index_by { |u| u.tree_children = nil; u.id } # WE NEED TO USE THIS INSTEAD OF .parent !!!
    seen      = {}

    # Contruct tree
    userfiles.each do |file|
      current  = file # probably not necessary
      track_id = file.id # to detect loops
      while ! seen[current]
        break if current == top
        seen[current] = track_id
        parent_id     = current.parent_id # Can be nil! by_id[nil] will return 'top' 
        parent        = by_id[parent_id] # Cannot use current.parent, as this would destroy its :tree_children
        parent      ||= top
        break if seen[parent] && seen[parent] == track_id # loop
        parent.tree_children ||= []
        parent.tree_children << current
        current = parent
      end
    end

    # Flatten tree
    top.all_tree_children(0) # sets top children's levels to '0'
  end

  # Returns an array will all children or subchildren
  # of the userfile, as contructed by tree_sort.
  # Optionally, sets the :level pseudo attribute
  # to all current children, increasing it down
  # the tree.
  def all_tree_children(level = nil) #:nodoc:
    return [] if self.tree_children.blank?
    result = []
    self.tree_children.each do |child|
      child.level = level if level
      result << child
      result += child.all_tree_children(level ? level+1 : nil) if child.tree_children # the 'if' optimizes one recursion out
    end
    result
  end

  def level
    @level ||= 0
  end

  #Produces the list of files to display for a paginated Userfile index
  #view.
  def self.paginate(files, page, preferred_per_page)
    per_page = (preferred_per_page || Default_num_pages).to_i
    offset = (page.to_i - 1) * per_page

    WillPaginate::Collection.create(page, per_page) do |pager|
      pager.replace(files[offset, per_page])
      pager.total_entries = files.size
      pager
    end
  end

  #Filters the +files+ array of userfiles, based on the
  #tag filters in the +tag_filters+ array and +user+, the current user.
  def self.apply_tag_filters_for_user(files, tag_filters, user)
    current_files = files

    unless tag_filters.blank?
      tags = tag_filters.collect{ |tf| user.tags.find_by_name( tf )}
      current_files = current_files.select{ |f| (tags & f.get_tags_for_user(user)) == tags}
    end

    current_files
  end

  #Converts a filter request sent as a POST parameter from the
  #Userfile index page into the format used by the Session model
  #to store currently active filters.
  def self.get_filter_name(type, term)
    case type
    when 'name_search'
      term.blank? ? nil : 'name:' + term
    when 'tag_search'
      term.blank? ? nil : 'tag:' + term
    when 'jiv'
      'format:jiv'
    when 'minc'
      'format:minc'
    when 'cw5'
      'file:cw5'
    when 'flt'
      'file:flt'
    when 'mls'
      'file:mls'
    end
  end
  
  #Convert the array of +filters+ into an scope
  #to be used in pulling userfiles from the database.
  #Note that tag filters will not be converted, as they are
  #handled by the apply_tag_filters method.
  def self.convert_filters_to_scope(filters)
    scope = self.scoped({})

    filters.each do |filter|
      type, term = filter.split(':')
      case type
      when 'name'
        scope = scope.scoped(:conditions => ["(userfiles.name LIKE ?)", "%#{term}%"])
      when 'custom'
        custom_filter = UserfileCustomFilter.find_by_name(term)
        scope = custom_filter.filter_scope(scope)
      when 'file'
        case term
        when 'cw5'
          scope = scope.scoped(:conditions => ["(userfiles.name LIKE ? OR userfiles.name LIKE ? OR userfiles.name LIKE ? OR userfiles.name LIKE ?)", "%.flt", "%.mls", "%.bin", "%.cw5"])
        when 'flt'
          scope = scope.scoped(:conditions => ["(userfiles.name LIKE ?)", "%.flt"])
        when 'mls'
          scope = scope.scoped(:conditions => ["(userfiles.name LIKE ?)", "%.mls"])
        end
      end
    end
    
    scope
  end

  #Returns whether or not +user+ has access to this
  #userfile.
  def can_be_accessed_by?(user, requested_access = :write)
    if user.has_role? :admin
      return true
    end
    if user.has_role?(:site_manager) && self.user.site_id == user.site_id && self.group.site_id == user.site_id
      return true
    end
    if user.id == self.user_id
      return true
    end
    if user.group_ids.include?(self.group_id) && (self.group_writable || requested_access == :read)
      return true
    end

    false
  end

  #Returns whether or not +user+ has owner access to this
  #userfile.
  def has_owner_access?(user)
    if user.has_role? :admin
      return true
    end
    if user.has_role?(:site_manager) && self.user.site_id == user.site_id && self.group.site_id == user.site_id
      return true
    end
    if user.id == self.user_id
      return true
    end

    false
  end


  #Find userfile identified by +id+ accessible by +user+.
  #
  #*Accessible* files are:
  #[For *admin* users:] any file on the system.
  #[For <b>site managers </b>] any file that belongs to a user of their site,
  #                            or assigned to a group to which the user belongs.
  #[For regular users:] all files that belong to the user all
  #                     files assigned to a group to which the user belongs.
  def self.find_accessible_by_user(id, user, options = {})
    access_options = {}
    access_options[:access_requested] = options.delete :access_requested
    
    scope = self.scoped(options)
    
    unless user.has_role?(:admin)
      scope = Userfile.restrict_access_on_query(user, scope, access_options)      
    end


    if user.has_role? :site_manager
      scope.find(id) rescue user.site.userfiles_find_id(id, options)
    else
      scope.find(id)
    end
  end

  #Find all userfiles accessible by +user+.
  #
  #*Accessible* files are:
  #[For *admin* users:] any file on the system.
  #[For <b>site managers </b>] any file that belongs to a user of their site,
  #                            or assigned to a group to which the user belongs.
  #[For regular users:] all files that belong to the user all
  #                     files assigned to a group to which the user belongs.
  def self.find_all_accessible_by_user(user, options = {})
    access_options = {}
    access_options[:access_requested] = options.delete :access_requested
    
    scope = self.scoped(options)
    
    unless user.has_role?(:admin)
      scope = Userfile.restrict_access_on_query(user, scope, access_options)      
    end


    if user.has_role? :site_manager
      user.site.userfiles_find_all(options) | scope.all
    else
      scope.all
    end
  end

  #This method takes in an array to be used as the :+conditions+
  #parameter for Userfile.find and modifies it to restrict based
  #on file ownership or group access.
  def self.restrict_access_on_query(user, scope, options = {})
    access_requested = options[:access_requested] || :write
    
    data_provider_ids = DataProvider.find_all_accessible_by_user(user).map(&:id)
        
    if access_requested.to_sym == :read
      scope = scope.scoped(:conditions  => ["((userfiles.user_id = ?) OR (userfiles.group_id IN (?) AND userfiles.data_provider_id IN (?)))", 
                                            user.id, user.group_ids, data_provider_ids])
    else
      scope = scope.scoped(:conditions  => ["((userfiles.user_id = ?) OR (userfiles.group_id IN (?) AND userfiles.data_provider_id IN (?) AND userfiles.group_writable = true))", 
                                            user.id, user.group_ids, data_provider_ids])
    end
    
    scope
  end

  #This method takes in an array to be used as the :+conditions+
  #parameter for Userfile.find and modifies it to restrict based
  #on the site.
  #
  #Note: Requires that the +users+ table be joined, either
  #of the <tt>:join</tt> or <tt>:include</tt> options.
  def self.restrict_site_on_query(user, scope)
    scope.scoped(:conditions => ["(users.site_id = ?)", user.site_id])
  end

  #Set the attribute by which to sort the file list
  #in the Userfile index view.
  def self.set_order(new_order, current_order)
    if new_order == 'size'
      new_order = 'type, ' + new_order
    end

    if new_order == current_order && new_order != 'userfiles.lft'
      new_order += ' DESC'
    end

    new_order
  end

  #This method returns true if the string +basename+ is an
  #acceptable name for a userfile. We restrict the filenames
  #to contain printable characters only, with no slashes
  #or ASCII nulls, and they must start with a letter or digit.
  def self.is_legal_filename?(basename)
    return true if basename.match(/^[a-zA-Z0-9][\w\~\!\@\#\$\%\^\&\*\(\)\-\+\=\:\;\[\]\{\}\|\<\>\,\.\?]*$/)

    false
  end

  #Returns the name of the Userfile in an array (only here to
  #maintain compatibility with the overridden method in
  #FileCollection).
  def list_files(*args)
    @file_list ||= {}
   
    @file_list[args.dup] ||= if self.is_locally_cached?
                               self.cache_collection_index(*args)
                             else
                               self.provider_collection_index(*args)
                             end
  end
  
  # Calculates and sets the size attribute unless
  # it's already set.
  def set_size
    self.set_size! if self.size.blank?
  end 

  # Calculates and sets.
  # (Abstract: should be redefined in subclass).
  def set_size!
    raise "set_size! called on Userfile. Should only be called in a subclass."
  end

  # Returns a simple keyword identifying the type of
  # the userfile; used mostly by the index view.
  def pretty_type
    "(???)"
  end

  ##############################################
  # Tree Traversal Methods
  ##############################################

  def move_to_child_of(userfile)
    if self.id == userfile.id || self.descendants.include?(userfile)
      raise ActiveRecord::ActiveRecordError, "A userfile cannot become the child of one of its own descendants." 
    end
    
    self.parent_id = userfile.id
    self.save!
        
    true
  end

  def descendants(seen = {})
    result     = []
    seen[self] = true
    self.children.each do |child|
      next if seen[child] # defensive, against loops
      seen[child] = true
      result << child
      result += child.descendants(seen)
    end
    result
  end



  ##############################################
  # Sequential traversal methods.
  ##############################################
  
  def next_available_file(user, options = {})
    userfiles = Userfile.find_all_accessible_by_user(user, options)
    return nil if userfiles.empty?
    return nil if self.id >= userfiles.last.id
    
    file = userfiles.find{ |u| u.id > self.id }
    
    file
  end

  def previous_available_file(user, options = {})
    userfiles = Userfile.find_all_accessible_by_user(user, options)
    return nil if userfiles.empty?
    return nil if self.id <= userfiles.first.id
    
    file = userfiles[userfiles.rindex{ |u| u.id < self.id }]

    file
  end
  
  ##############################################
  # Synchronization Status Access Methods
  ##############################################

  # Forces the userfile to be marked
  # as 'newer' on the provider side compared
  # to whatever is in the local cache for the
  # current Rails application. Not often used.
  # Results in the destruction of the local
  # sync status object.
  def provider_is_newer
    SyncStatus.ready_to_modify_dp(self) do
      true
    end
  end

  # Forces the userfile to be marked
  # as 'newer' on the cache side of the current
  # Rails application compared to whatever is in
  # the official data provider.
  # Results in the the local sync status object
  # to be marked as 'CacheNewer'.
  def cache_is_newer
    SyncStatus.ready_to_modify_cache(self) do
      true
    end
  end

  # This method returns, if it exists, the SyncStatus
  # object that represents the syncronization state of
  # the content of this userfile on the local RAILS
  # application's DataProvider cache. Returns nil if
  # no SyncStatus object currently exists for the file.
  def local_sync_status(refresh = false)
    @syncstat = nil if refresh
    @syncstat ||= SyncStatus.find(:first, :conditions => {
      :userfile_id        => self.id,
      :remote_resource_id => CBRAIN::SelfRemoteResourceId
    } )
  end

  # Returns whether this userfile's contents has been
  # synced to the local cache.
  def is_locally_synced?
    syncstat = self.local_sync_status
    return true if syncstat && syncstat.status == 'InSync'
    return false unless self.data_provider.is_fast_syncing?
    self.sync_to_cache
    syncstat = self.local_sync_status(:refresh)
    return true if syncstat && syncstat.status == 'InSync'
    false
  end
  
  # Returns whether this userfile's contents has been
  # is in the local cache and valid.
  #
  # The difference between this method and is_locally_synced?
  # is that this method will also return true if the contents
  # are more up to date on the cache than on the provider
  # (and thus are not officially "In Sync").
  def is_locally_cached?
    return true if is_locally_synced?
    
    syncstat = self.local_sync_status
    syncstat && syncstat.status == 'CacheNewer'
  end

  ##############################################
  # Data Provider easy access methods
  ##############################################

  # See the description in class DataProvider
  def sync_to_cache
    self.data_provider.sync_to_cache(self)
  end

  # See the description in class DataProvider
  def sync_to_provider
    self.data_provider.sync_to_provider(self)
    self.set_size!
  end

  # See the description in class DataProvider
  def cache_erase
    self.data_provider.cache_erase(self)
  end

  # See the description in class DataProvider
  def cache_prepare
    self.save! if self.id.blank? # we need an ID to prepare the cache
    self.data_provider.cache_prepare(self)
  end

  # See the description in class DataProvider
  def cache_full_path
    self.data_provider.cache_full_path(self)
  end

  # See the description in class DataProvider
  def provider_erase
    self.data_provider.provider_erase(self)
  end

  # See the description in class DataProvider
  def provider_rename(newname)
    self.data_provider.provider_rename(self, newname)
  end

  # See the description in class DataProvider
  def provider_move_to_otherprovider(otherprovider)
    self.data_provider.provider_move_to_otherprovider(self, otherprovider)
  end
  
  # See the description in class DataProvider
  def provider_copy_to_otherprovider(otherprovider,newname = nil)
    self.data_provider.provider_copy_to_otherprovider(self,otherprovider,newname)
  end

  # See the description in class DataProvider
  def provider_collection_index(directory = :all, allowed_types = :regular)
    self.data_provider.provider_collection_index(self, directory, allowed_types)
  end

  # See the description in class DataProvider
  def provider_readhandle(*args, &block)
    self.data_provider.provider_readhandle(self, *args,  &block)
  end

  # See the description in class DataProvider
  def cache_readhandle(*args, &block)
    self.data_provider.cache_readhandle(self, *args,  &block)
  end

  # See the description in class DataProvider
  def cache_writehandle(*args, &block)
    self.save!
    self.data_provider.cache_writehandle(self, *args, &block)
    self.set_size!
  end

  # See the description in class DataProvider
  def cache_copy_from_local_file(filename)
    self.save!
    self.data_provider.cache_copy_from_local_file(self, filename)
    self.set_size!
  end

  # See the description in class DataProvider
  def cache_copy_to_local_file(filename)
    self.save!
    self.data_provider.cache_copy_to_local_file(self, filename)
  end
  
  # Returns an Array of FileInfo objects containing
  # information about the files associated with this Userfile
  # entry.
  #
  # Information is requested from the cache (not the actual data provider).
  def cache_collection_index(directory = :all, allowed_types = :regular)
    self.data_provider.cache_collection_index(self, directory, allowed_types)
  end
  
  # Returns true if the data provider for the content of
  # this file is online.
  def available?
    self.data_provider.online?
  end
  
  def content(options)
    false
  end


  private
  
  def self.has_viewer(*new_viewers)
    new_viewers.map!{ |v| Viewer.new(v) }
    new_viewers.each{ |v| add_viewer(v) }
  end
  
  def self.has_viewers(*new_viewers)
    self.has_viewer(*new_viewers)
  end
  
  def self.reset_viewers
    @ancestor_viewers = []
    @class_viewers    = []
  end
  
  def self.add_viewer(viewer)
    if self.class_viewers.find{ |v| v == viewer  }
      cb_error "Redefinition of viewer in class #{self.name}."
    end
    
    @class_viewers << viewer
  end
  
  def self.class_viewers
    unless @ancestor_viewers
      if self.superclass.respond_to? :class_viewers
        @ancestor_viewers = self.superclass.class_viewers
      end
    end
    @ancestor_viewers ||= []
    @class_viewers    ||= []
    class_v    = (@class_viewers).clone
    ancestor_v = (@ancestor_viewers).clone
    
    class_v + ancestor_v
  end
  
  def validate_associations
    unless DataProvider.find(:first, :conditions => {:id => self.data_provider_id})
      errors.add(:data_provider, "does not exist.")
    end
    unless User.find(:first, :conditions => {:id => self.user_id})
      errors.add(:user, "does not exist.")
    end
    unless Group.find(:first, :conditions => {:id => self.group_id})
      errors.add(:group, "does not exist.")
    end
  end

  def validate_filename
    unless Userfile.is_legal_filename?(self.name)
      errors.add(:name, "contains invalid characters.")
    end
  end
  
  def erase_or_unregister
    unless self.data_provider.is_browsable?
      self.provider_erase
    end
    self.cache_erase
    true
  end
  
  def format_tree_update
    return true if self.format_source
    
    format_children = self.formats
    return true if format_children.empty?
    
    new_source = format_children.shift
    new_source.update_attributes!(:format_source_id  => nil)
    format_children.each do |fmt|
      fmt.update_attributes!(:format_source_id  => new_source.id)
    end
  end
  
  def nullify_children
    self.children.each do |c|
      c.parent_id = nil
      c.save!
    end    
  end
   
end

