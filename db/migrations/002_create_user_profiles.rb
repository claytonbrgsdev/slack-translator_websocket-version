Sequel.migration do
  change do
    create_table(:user_profiles) do
      primary_key :id
      String      :user_id, null: false, unique: true
      Text        :profile_json, null: false  # Use JSONB if migrating to Postgres later
      DateTime    :fetched_at, null: false
      index       :user_id, unique: true
      index       :fetched_at               # For faster pruning of old profiles
    end
  end
end
