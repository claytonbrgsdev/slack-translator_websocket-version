require_relative '../db/config'
require 'json'

# Model for persistent user profile cache
class UserProfile < Sequel::Model(:user_profiles)
  # Constants
  CACHE_TTL = 60 * 60 * 24  # 24 hours in seconds
  MAX_AGE = 60 * 60 * 24 * 7 # 7 days in seconds
  
  # Get a profile by user_id
  # @param user_id [String] Slack user ID
  # @return [Hash, nil] User profile hash if found and fresh, or nil if not found/expired
  def self.get_profile(user_id)
    profile = self.find(user_id: user_id)
    
    if profile
      fetched_time = profile.fetched_at
      current_time = Time.now
      age = current_time - fetched_time
      
      if age < CACHE_TTL
        puts "[PROFILE CACHE] DB cache hit for user #{user_id} (age: #{(age/3600).round(1)}h)"
        return JSON.parse(profile.profile_json)
      else
        puts "[PROFILE CACHE] Stale cache for user #{user_id} (age: #{(age/3600).round(1)}h)"
        return nil
      end
    end
    
    puts "[PROFILE CACHE] No cache entry for user #{user_id}"
    nil
  end
  
  # Save a profile to the cache using efficient upsert
  # @param user_id [String] Slack user ID
  # @param profile_data [Hash] User profile data
  # @return [Boolean] Success status
  def self.save_profile(user_id, profile_data)
    profile_json = profile_data.to_json
    timestamp = Time.now
    
    # Use Sequel's native insert_conflict for atomic upsert
    # This avoids SELECT+INSERT/UPDATE race conditions under high concurrency
    DB[:user_profiles].insert_conflict(
      target: :user_id,
      update: { 
        profile_json: profile_json, 
        fetched_at: timestamp 
      }
    ).insert(
      user_id: user_id, 
      profile_json: profile_json, 
      fetched_at: timestamp
    )
    
    puts "[PROFILE CACHE] Saved profile for user #{user_id}"
    return true
  end
  
  # Prune old profiles from the cache
  # @return [Integer] Number of profiles pruned
  def self.prune_old_profiles
    count = 0
    
    old_time = Time.now - MAX_AGE
    self.where { fetched_at < old_time }.each do |profile|
      profile.delete
      count += 1
    end
    
    puts "[PROFILE CACHE] Pruned #{count} old profiles"
    count
  end
end
