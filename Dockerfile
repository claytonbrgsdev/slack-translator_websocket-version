FROM ruby:3.2.2-alpine
RUN apk add --no-cache build-base
WORKDIR /app
COPY Gemfile* ./
RUN gem install bundler && bundle install
COPY . .
EXPOSE 4567
CMD ["ruby", "server.rb"]
