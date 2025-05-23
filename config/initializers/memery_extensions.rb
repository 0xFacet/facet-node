module MemeryExtensions
  class << self
    attr_accessor :included_classes_and_modules
  end

  self.included_classes_and_modules = [].to_set

  def included(base = nil, &block)
    # Call the original included method
    super

    # Track the class or module that includes Memery
    MemeryExtensions.included_classes_and_modules << base
  end

  def self.clear_all_caches!
    MemeryExtensions.included_classes_and_modules.each do |mod|
      if mod.respond_to?(:clear_memery_cache!)
        mod.clear_memery_cache!
      end

      # Check if the singleton class responds to clear_memery_cache!
      if mod.singleton_class.respond_to?(:clear_memery_cache!)
        mod.singleton_class.clear_memery_cache!
      end
    end
  end
end

module MemeryClassMethodsExtensions
  def class_memoize(*method_names)
    singleton_class.class_eval do
      include Memery unless singleton_class.included_modules.include?(Memery)
      memoize(*method_names)
    end
  end
end

# Prepend MemeryExtensions to Memery::ModuleMethods
Memery::ModuleMethods.prepend(MemeryExtensions)
Memery::ClassMethods.prepend(MemeryClassMethodsExtensions)

# Register a reloader hook to reset the checksum and clear caches
ActiveSupport::Reloader.to_prepare do
  SolidityCompiler.reset_checksum
  # Rails.cache.clear
  MemeryExtensions.clear_all_caches!
end
