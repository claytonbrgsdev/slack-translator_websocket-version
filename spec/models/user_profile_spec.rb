require 'spec_helper'
require_relative '../../models/user_profile'

RSpec.describe UserProfile do
  let(:user_id) { 'U12345XYZ' }
  let(:profile_data) { {'real_name' => 'Test User', 'display_name' => 'testuser', 'image_72' => 'http://example.com/avatar.jpg'} }
  
  before do
    # Clear the test database before each test
    DB[:user_profiles].delete
    
    # Clear the in-memory cache in SlackUserService
    SlackUserService.instance_variable_set(:@user_profiles, {})
    SlackUserService.instance_variable_set(:@profile_timestamps, {})
  end
  
  describe '.get_profile' do
    it 'returns nil when profile does not exist' do
      expect(UserProfile.get_profile(user_id)).to be_nil
    end
    
    it 'returns the profile when it exists and is fresh' do
      UserProfile.save_profile(user_id, profile_data)
      
      result = UserProfile.get_profile(user_id)
      expect(result).to eq(profile_data)
    end
    
    it 'returns nil when profile exists but is stale' do
      # Create a stale profile (older than 24 hours)
      DB[:user_profiles].insert(
        user_id: user_id,
        profile_json: profile_data.to_json,
        fetched_at: Time.now - 60*60*25 # 25 hours ago
      )
      
      expect(UserProfile.get_profile(user_id)).to be_nil
    end
  end
  
  describe '.save_profile' do
    it 'creates a new profile when it does not exist' do
      expect {
        UserProfile.save_profile(user_id, profile_data)
      }.to change { DB[:user_profiles].count }.by(1)
      
      saved = DB[:user_profiles].first
      expect(saved[:user_id]).to eq(user_id)
      expect(JSON.parse(saved[:profile_json])).to eq(profile_data)
    end
    
    it 'updates an existing profile' do
      # Create initial profile
      UserProfile.save_profile(user_id, profile_data)
      
      # Update with new data
      new_data = profile_data.merge('display_name' => 'updated_name')
      
      expect {
        UserProfile.save_profile(user_id, new_data)
      }.not_to change { DB[:user_profiles].count }
      
      saved = DB[:user_profiles].first
      expect(JSON.parse(saved[:profile_json])['display_name']).to eq('updated_name')
    end
  end
  
  describe '.prune_old_profiles' do
    it 'removes profiles older than the MAX_AGE' do
      # Create a fresh profile
      UserProfile.save_profile(user_id, profile_data)
      
      # Create an old profile
      old_user_id = 'UOLD12345'
      DB[:user_profiles].insert(
        user_id: old_user_id,
        profile_json: profile_data.to_json,
        fetched_at: Time.now - UserProfile::MAX_AGE - 3600 # 1 hour past MAX_AGE
      )
      
      expect {
        UserProfile.prune_old_profiles
      }.to change { DB[:user_profiles].count }.by(-1)
      
      # Verify only the old profile was removed
      expect(DB[:user_profiles].where(user_id: user_id).count).to eq(1)
      expect(DB[:user_profiles].where(user_id: old_user_id).count).to eq(0)
    end
  end
  
  describe 'Integration with SlackUserService' do
    it 'returns DB hit when in-memory is cleared' do
      # Save profile to DB
      UserProfile.save_profile(user_id, profile_data)
      
      # Clear in-memory cache
      SlackUserService.instance_variable_set(:@user_profiles, {})
      SlackUserService.instance_variable_set(:@profile_timestamps, {})
      
      # Mock HTTP to ensure we don't actually call Slack API
      allow(HTTP).to receive(:headers).and_raise("Shouldn't call HTTP")
      
      # Service should get profile from DB, not call Slack
      expect {
        result = SlackUserService.fetch_user_profile(user_id)
        expect(result).to eq(profile_data)
      }.not_to raise_error
    end
  end
end
