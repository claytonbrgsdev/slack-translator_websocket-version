require 'sequel'
if ENV['DATABASE_URL']
  DB = Sequel.connect(ENV['DATABASE_URL'])
else
  DB = Sequel.sqlite(File.join(__dir__, 'messages.sqlite3'))
end
