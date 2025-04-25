require 'sequel'
DB = Sequel.connect(ENV['DATABASE_URL'] || "sqlite://#{__dir__}/messages.sqlite3")
