Sequel.migration do
  change do
    create_table(:messages) do
      primary_key :id
      String      :envelope_id, null: false, unique: true
      String      :channel,     null: false
      String      :user_id,     null: false
      String      :text,        text: true, null: false
      String      :real_name
      String      :avatar_url
      String      :timestamp
      DateTime    :created_at,  default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
