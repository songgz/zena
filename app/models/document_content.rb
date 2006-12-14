require 'fileutils'
class DocumentContent < ActiveRecord::Base
  belongs_to            :version
  
  before_validation     :prepare_filename
  validate              :valid_file
  validates_presence_of :ext
  validates_presence_of :name
  validates_presence_of :version
  before_save           :save_file
  before_destroy        :destroy_file

  
  # format is ignored here
  def img_tag(format=nil)
    ext = self[:ext]
    unless File.exist?("#{RAILS_ROOT}/public/images/ext/#{ext}.png")
      ext = 'other'
    end
    unless format
      # img_tag from extension
      "<img src='/images/ext/#{ext}.png' width='32' height='32' class='icon'/>"
    else
      img = ImageBuilder.new(:path=>"#{RAILS_ROOT}/public/images/ext/#{ext}.png", :width=>32, :height=>32)
      img.transform!(format)
      path = "#{RAILS_ROOT}/public/images/ext/"
      filename = "#{ext}-#{format}.png"
      unless File.exist?(File.join(path,filename))
        # make new image with the format
        unless File.exist?(path)
          FileUtils::mkpath(path)
        end
        if img.dummy?
          File.cp("#{RAILS_ROOT}/public/images/ext/#{ext}.png", "#{RAILS_ROOT}/public/images/ext/#{ext}-#{format}.png")
        else
          File.open(File.join(path, filename), "wb") { |f| f.syswrite(img.read) }
        end
      end
      "<img src='/images/ext/#{filename}' width='#{img.width}' height='#{img.height}' class='#{format}'/>"
    end
  end
  
  def file=(aFile)
    @file = aFile
    self[:content_type] = @file.content_type.chomp
    # FIXME: crash when StringIO
    self[:size] = @file.stat.size
  end
  
  def size=(s)
    raise StandardError, "Size cannot be set. It is defined by the file size."
  end
  
  def file(format=nil)
    if @file
      @file
    elsif File.exist?(filepath)
      File.new(filepath)
    else
      raise IOError, "File not found"
    end
  end
  
  def size(format=nil)
    return self[:size] if self[:size]
    if !new_record? && File.exist?(filepath)
      self[:size] = File.stat(filepath).size
      self.save
    end
    self[:size]
  end
  
  def filename(format=nil)
    "#{name}.#{ext}"
  end
  
  def path(format=nil)
    "/#{ext}/#{self[:version_id]}/#{filename(format)}"
  end
  
  # path is build with the version id so we can do the security checks when uploading data
  def filepath(format=nil)
    raise StandardError, "version not set" unless self[:version_id]
    "#{RAILS_ROOT}/data/#{RAILS_ENV}#{path(format)}"
  end
  
  private

  def prepare_filename
    self[:name] = version.item.name
    if @file
      # set extension
      ext  = self[:ext] || @file.original_filename.split('.').last
      # is this extension valid ?
      extensions = TYPE_TO_EXT[self[:content_type]]
      if extensions
        self[:ext] = extensions.include?(ext) ? ext : extensions[0]
      else
        self[:ext] = "???"
      end
      
      # set size
      self[:size] = @file.stat.size
      true
    end
  end
  
  def valid_file
    errors.add('file', "can't be blank") unless !new_record? || @file
  end

  def save_file
    if @file
      # destroy old file
      destroy_file unless new_record?
      # save new file
      make_file(filepath, @file)
    elsif (old = DocumentContent.find(self[:id])).name != self[:name]
      # TODO: clear cache
      # TODO: remove 'format' images
      FileUtils::mv(old.filepath, filepath)
    end
  end
  
  def make_file(path, data)
    p = File.join(*path.split('/')[0..-2])
    unless File.exist?(p)
      FileUtils::mkpath(p)
    end
    File.open(path, "wb") { |f| f.syswrite(data.read) }
  end
  
  def destroy_file
    # TODO: clear cache
    old_path = DocumentContent.find(self[:id]).filepath
    folder = File.join(*old_path.split('/')[0..-2])
    if File.exist?(folder)
      FileUtils::rmtree(folder)
    end
    # TODO: set content_id of versions whose content_id was self[:version_id]
  end
end
