class MailLib

  # initialize mailer settings
  def initialize(config)
    @address = config['address']
    @port = config['port']
    @domain = config['domain']
    @user_name = config['user_name']
    @password = config['password']
    @from = config['from']
    @to = config['to']
    @default = config['default']
  end

  def resolve_to(tag, allow_default)
    to = nil
    to = @default if allow_default
    to = @to[tag] if @to[tag]
    to
  end

  def send(to, subject, body, html_body, json = nil)
    $log.info("send: to: #{to}, sub: #{subject}, body: #{body}")

    smtp_options = {
      :address => @address,
      :enable_starttls_auto => true,
      :port => @port,
      :user_name => @user_name, :password => @password, :authentication => :plain,
      :domain => @domain
    }
    $log.info("s2: smtp_options: #{smtp_options.pretty_inspect}")

    Pony.mail(:to => to, :from => @from,
        :subject => subject,
        :body => body, :html_body => html_body,
        :via => :smtp,
        :via_options => smtp_options,
        :attachments => json
      )
  end
end
