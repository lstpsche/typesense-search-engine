# frozen_string_literal: true

# Base mailer for the dummy host app.
class ApplicationMailer < ActionMailer::Base
  default from: 'from@example.com'
  layout 'mailer'
end
