require 'clockwork'
require './config/boot'
require './config/environment'
require 'active_support/time'

module Clockwork
  handler do |job|
    puts "Running #{job}"
  end

  error_handler do |error|
    report_exception_every = 15.minutes
    
    exception_key = ["clockwork-airbrake", error.class, error.message, error.backtrace[0]]
    
    last_reported_at = Rails.cache.read(exception_key)

    if last_reported_at.blank? || (Time.zone.now - last_reported_at > report_exception_every)
      Airbrake.notify(error)
      Rails.cache.write(exception_key, Time.zone.now)
    end
  end

  every(6.seconds, 'import_blocks_until_done') do
    unless ENV['FACET_V1_VM_DATABASE_URL'].present?
      raise "FACET_V1_VM_DATABASE_URL is not set"
    end
    
    LegacyMigrationDataGenerator.instance.import_blocks_until_done
  end
end
