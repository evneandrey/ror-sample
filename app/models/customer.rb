class Customer < ApplicationRecord
    belongs_to :user
    belongs_to :operator
    belongs_to :channel

    attr_accessor :importing_rows

    after_create :set_dynamics_dates_when_create
    before_update :set_dynamics_dates_when_update, :set_lead_date_when_update, :set_is_converted_customer
    before_destroy :set_deleted_date
    before_create :set_lead_date_when_create, :set_imported_as_status

    scope :with_inviter, -> { joins("LEFT JOIN (SELECT id, email as inviter_email, CONCAT_WS(' ', first_name, last_name) AS inviter_full_name FROM users) AS inviters ON users.invited_by_id = inviters.id") }
    scope :with_short_links, -> (short_links_sql) { select(:id, :user_id, :operator_id, :channel_id, :conversation_template_id, "(#{short_links_sql}) as short_link_key")
                                                     .to_h { |c| [c.id, c.attributes['short_link_key']] } }
    scope :non_status, -> { where(status: 0) }
    scope :customers, -> { where(status: 2) }
    scope :loses, -> { where(status: 3) }
    scope :leads, -> { where(status: 1) }

    scope :users_ids, -> (user_ids) { where(user_id:user_ids) if user_ids.present? }
    scope :by_customer_ids, -> (customer_ids) { where(id: customer_ids) if customer_ids.present? }

    #Logic behind the following scopes is that where dates are very similar, they are directly set to customer or imported.
    scope :in_conversation_imported, -> { joins([{:user => {:conversation_messages => {:conversation => :template}}}]).
                                                    where("brands_users.created_at::date < " +
                                                          "((SELECT messages.created_at WHERE brands_users.operator_id = conversation_templates.operator_id ORDER BY messages.created_at ASC LIMIT 1))::date").distinct }#this is a hack until customer_updated at this updated on change.
    scope :in_conversation_not_imported, -> { joins([{:user => {:conversation_messages => {:conversation => :template}}}]).
                                                    where("brands_users.created_at::date >= " +
                                                          "((SELECT messages.created_at WHERE brands_users.operator_id = conversation_templates.operator_id ORDER BY messages.created_at ASC LIMIT 1))::date").distinct }#this is a hack until customer_updated at this updated on change.
    scope :not_created_direct_to_customer_in_conversation, -> { joins([{:user => {:conversation_messages => {:conversation => :template}}}]).
                                               where.not("brands_users.status = 2 AND users.created_at::timestamp BETWEEN " +
                                                           "((SELECT messages.created_at WHERE brands_users.operator_id = conversation_templates.operator_id ORDER BY messages.created_at ASC LIMIT 1) - '3 seconds'::interval)::timestamp AND " +
                                                           "(SELECT messages.created_at WHERE brands_users.operator_id = conversation_templates.operator_id ORDER BY messages.created_at DESC LIMIT 1)::timestamp").distinct }#this is a hack until customer_updated at this updated on change.

    scope :with_cust_acq_promo, -> { joins({:operator => {:coupons => :advertisement}}).where("coupons.user_id = brands_users.user_id AND advertisements.category = 22") }
    scope :by_operator_id, -> (operator_id) { where(operator_id ? "brands_users.operator_id = ?" : 'TRUE', operator_id) }

    scope :with_messages_date, -> (operator_id, type) { select("(SELECT " + type_messages_date(type) + "(messages.created_at) FROM messages
                                                              LEFT JOIN conversations ON messages.conversation_id = conversations.id
                                                              LEFT JOIN operator_channels ON conversations.channel_id = operator_channels.id
                                                              WHERE conversations.sender_id = brands_users.user_id AND operator_channels.operator_id = " + operator_id +"
                                                            ) AS " + type + "_message_date") }

    scope :with_search, -> (search) { where("CONCAT_WS(' ', users.first_name, users.last_name) ILIKE ? OR email ILIKE ?", "%#{search}%", "%#{search}%") if search.present? }

    scope :filter_by_date_range, -> (date_from, date_till) { where('brands_users.created_at' => date_from.to_date.beginning_of_day..date_till.to_date.end_of_day) if date_from.present? && date_till.present? }

    scope :preferred_reward_filter_data, -> (user_ids, operator_id) { select("DISTINCT currencies.id, currencies.title")
                                                            .joins("INNER JOIN coupons ON brands_users.user_id = coupons.user_id")
                                                            .joins("INNER JOIN rewards ON rewards.id = coupons.reward_id")
                                                            .joins("INNER JOIN currencies ON currencies.id = rewards.currency")
                                                            .where('coupons.user_id IN (?) AND coupons.operator_id = ?', user_ids, operator_id) }

    scope :filter_by_preferred_rewards, -> (currency_id) { select('DISTINCT currencies.id, users.*')
                                                               .joins("LEFT JOIN coupons ON brands_users.user_id = coupons.user_id")
                                                               .joins("LEFT JOIN rewards ON rewards.id = coupons.reward_id")
                                                               .joins("LEFT JOIN currencies ON currencies.id = rewards.currency")
                                                               .where("currencies.id = ?", currency_id) if currency_id.present?}

    scope :with_preferred_rewards, -> (currency_keys) { select('DISTINCT currencies.id, currencies.title')
                                                            .joins("LEFT JOIN coupons ON brands_users.user_id = coupons.user_id")
                                                            .joins("LEFT JOIN rewards ON rewards.id = coupons.reward_id")
                                                            .joins("LEFT JOIN currencies ON currencies.id = rewards.currency")
                                                            .where("currencies.key IN (?)", currency_keys) if currency_keys.present? }

    scope :filter_by_campaigns, -> (campaign_id) { where(:channel_id => campaign_id) if campaign_id.present? }

    scope :select_user_ids, -> (operator_id) { where(:status => [1, 2, 3], :operator_id => operator_id).where.not(:user_id => nil).pluck('user_id') }

    scope :filter_by_category, -> (category) { set_filter_by_category(category) }
    scope :filter_by_type, -> (type) { set_filter_by_type(type) }
    scope :filter_with_positive_balance, -> (positive_balance) { where("get_tbi(brands_users.user_id, brands_users.operator_id) > 0") if positive_balance.present? && to_boolean(positive_balance) == true }
    scope :with_lead_to_customer_date, -> { joins("LEFT JOIN customers_dynamics ON customers_dynamics.customer_id = brands_users.id") }
    scope :select_invitations, -> (user_ids) { select("users.*, brands_users.user_id as customer_user_id, users.invited_by_id as ibi").joins("INNER JOIN users ON brands_users.user_id = users.invited_by_id")
                                               .where(:user_id => user_ids) }

    scope :with_promos_presented_count, -> (promos_presented) {
      select("
            (
                SELECT COUNT(campaigns.*) FROM coupons
                INNER JOIN advertisements ON coupons.advertisement_id = advertisements.id
                INNER JOIN campaigns ON advertisements.campaign_id = campaigns.id
                WHERE coupons.user_id = brands_users.user_id AND campaigns.id = #{promos_presented}
            ) AS promos_presented
      ") if promos_presented.present?
    }

    scope :filter_promos_presented, -> (promos_presented) {
      if promos_presented.present?
        select("filtered_promos_presented.*").where('filtered_promos_presented.promos_presented > 0')
      else
        select("filtered_promos_presented.*")
      end
    }

    scope :with_has_received_reward_count, -> (operator_id, has_received_reward) {
      if has_received_reward.present?
        vouchers_query = Voucher.select("COUNT(*)").by_operator_id(operator_id).customer_only.to_sql
        select("(#{vouchers_query} AND brands_users.user_id = vouchers.user_id) as vouchers_count")
      end
    }

    scope :filter_has_received_reward, -> (has_received_reward) {
      if has_received_reward.present?
        select("filtered_has_received_reward.*").where('filtered_has_received_reward.vouchers_count > 0')
      else
        select("filtered_has_received_reward.*")
      end
    }

    scope :user_ids_for_survey_filter, -> (operator_id, ranking_user_ids) { select("DISTINCT user_id").where("operator_id = ? AND user_id IN(?)", operator_id, ranking_user_ids) }

    def self.type_messages_date(type)
      type == 'first' ? 'MIN' : 'MAX'
    end

    def status_name
      case status
      when 1
        :lead
      when 2
        :customer
      when 3
        :lost
      else
        nil
      end
    end

    def imported_as_status_name
      case imported_as_status
      when 1
        :lead
      when 2
        :customer
      when 3
        :lost
      else
        nil
      end
    end

    def self.short_links_sql
      return "(#{ShortLink.short_links_sql}) as short_link_key"
    end

    def self.set_filter_by_category(category)
      case category
      when "none"
        where(:status => 0)
      when "leads"
        where(:status => 1)
      when "customers"
        where(:status => 2)
      when "loses"
        where(:status => 3)
      when "converted_customers"
        where(:is_converted_customer => 1)
      end
    end

    def self.set_filter_by_type(type)
      case type
      when "not_imported"
        where(:is_imported => 0)
      when "imported"
        where(:is_imported => 1)
      when "imported_lost"
        where(:imported_as_status => 3)
      when "imported_customers"
        where(:imported_as_status => 2)
      when "imported_leads"
        where(:imported_as_status => 1)
      end
    end

    def self.generate_vouchers(operator, ids = [], product_id = '', is_admin = false)
        new_customer_vouchers = {}
        self.where(:operator_id => operator.id, :id => ids).all.each do |customer|
            if customer.user.present?
                if !product_id.blank? && is_admin
                    currency = Currency.find_by_product_id(product_id)
                    product_balance = currency ? customer.user.balance(operator.id)[currency.key] ? customer.user.balance(operator.id)[currency.key][:value].to_f : 0 : 0
                    if product_balance > 0
                        api_response = ApiService.generate_voucher_with_api({
                                                                                :value => product_balance,
                                                                                :code => "CV#{customer.id}-#{customer.user_id}-#{customer.operator_id}",
                                                                                :operator_id => operator.id,
                                                                                :channel_id => customer.channel_id,
                                                                                :used => false,
                                                                                :currency_id => currency.id,
                                                                                :user_id => customer.user_id,
                                                                                :product_id => currency.product_id,
                                                                                :provider_id => currency.provider_id
                                                                            })
                        raise "error generating voucher from api: #{api_response}" if api_response.kind_of? HTTP::ResponseError
                        raise "error connecting to api: #{api_response}" if api_response.kind_of? HTTP::ConnectionError
                        raise "other error creating voucher with api, contact admin: #{api_response}" if api_response.kind_of? HTTP::Error

                        new_customer_vouchers[customer.id] = 0 unless new_customer_vouchers[customer.id].present?
                        Voucher.create(:value => product_balance, :code => "CV#{customer.id}-#{customer.user_id}-#{customer.operator_id}", :operator_id => operator.id, :used => false, :currency_id => currency.id, :user_id => customer.user_id)
                        new_customer_vouchers[customer.id] += (product_balance * currency.conversion_rate) / Rails.application.config.eur_exchange_rate.to_f
                    end
                else
                    balances = customer.user.balance(operator.id)
                    balances.keys.each do |currency_key|
                        currency = Currency.where(:product_id => product_id).find_by(:key => currency_key, :exported => true)
                        if currency.present?
                            balance = balances[currency_key][:value].to_f
                            if balance > 0
                                new_customer_vouchers[customer.id] = 0 unless new_customer_vouchers[customer.id].present?
                                Voucher.create(:value => balance, :code => "CV#{customer.id}-#{customer.user_id}-#{customer.operator_id}", :operator_id => operator.id, :used => false, :currency_id => currency.id, :user_id => customer.user_id)
                                new_customer_vouchers[customer.id] += (balance * currency.conversion_rate) / Rails.application.config.eur_exchange_rate.to_f
                            end
                        end
                    end
                end
            end
        end
        new_customer_vouchers
    end

    def self.deduction(operator, ids = [])
        self.where(:operator_id => operator.id, :id => ids).all.each do |customer|
            if customer.user.present?
                balances = customer.user.balance(operator.id)
                balances.keys.each do |currency_key|
                    currency = Currency.find_by(:key => currency_key)
                    balance = balances[currency_key][:value].to_f
                    Voucher.create(:value => balance, :code => "CV#{customer.id}-#{customer.user_id}-#{customer.operator_id}", :operator_id => operator.id, :used => false, :currency_id => currency.id, :user_id => customer.user_id) if balance > 0
                end
            end
        end
    end

    def self.for_print_data(customers, date_from, date_to)
        {
            :date_from => date_from,
            :date_to => date_to,
            :summary => {
                :total => customers.select{ |item| item[:status] != 0 }.size,
                :none => customers.select{ |item| item[:status] == 0 }.size,
                :leads => customers.select{ |item| item[:status] == 1 }.size,
                :customers => customers.select{ |item| item[:status] == 2 }.size,
                :lost => customers.select{ |item| item[:status] == 3 }.size
            },
            :customers => customers
        }
    end

  def self.for_export_data(customers)
    sizes_array = customers.collect{|c| c.keys.size}
    max_index = sizes_array.index(sizes_array.max)
    headers = customers[max_index].keys
    CSV.generate do |csv|
      csv << headers
      if customers.size > 0
        customers.each do |c|
          row_data = c.values
          csv << row_data
        end
      end
    end
  end



  def is_valid_import_file(file)
    self.importing_rows = []
    unless file.content_type == "application/vnd.ms-excel" || file.content_type == "text/csv" || file.content_type == "application/csv" || (file.content_type == "text/plain" && file.original_filename.include?('.csv'))
        self.errors[:file] << "Imported file must be only csv type"
        return false
    end
    csv_file_length = CSV.read(file.path).length - 1
    if csv_file_length > 50000
      self.errors[:file] << "File exceeds the allowed limits 50 000 rows"
      return false
    end
    begin
        rows = []
        CSV.foreach(file.path, :headers => true, :header_converters => :symbol) do |row|
            if row[:email].blank?
                self.errors[:file] << "Field \"email\" is required"
                return false
            end
            email = row[:email].strip
            if !(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i =~ email)
                self.errors[:file] << "Field \"email\" must be a valid email address"
                return false
            end
            if row[:firstname].blank?
                self.errors[:file] << "Field \"firstName\" is required"
                return false
            end
            if row[:lastname].blank?
                self.errors[:file] << "Field \"lastName\" is required"
            end

            rows << { email: email, firstname: row[:firstname], lastname: row[:lastname] }
        end

        rows.uniq! { |row| row[:email] }
        rows.in_groups_of(500, false) { |group| self.importing_rows << group }
    rescue Exception => e
        self.errors[:file] << "Imported file content is not in csv format - #{e.message}" and return false
    end
    true
  end

  def self.import_data(company_id, operator_id, channel_id, conversation_id, inviter_id, chunk, customer_status, imported = true)
      result = nil
      insert_data = []
      insert_short_link_data = []
      chunk.each do |customer|
          user = User.find_by("Lower(email) =?", customer[:email].strip.downcase)
          if user.present?
              user.skip_confirmation!
              user.skip_confirmation_notification!
              user.update(:invited_by_id => inviter_id)
          else
              user = User.new(
                  :first_name => customer[:firstname].strip,
                  :last_name => customer[:lastname].strip,
                  :email => customer[:email].strip,
                  :invited_by_id => inviter_id,
                  :country_code => 'NO',
                  :continent_code => 'EU'
              )
              user.skip_confirmation!
              user.skip_confirmation_notification!
              user.save
          end
          unless Customer.exists?(:brand_id => company_id,
                                  :user_id => user.id,
                                  :operator_id => operator_id,
                                  :channel_id => channel_id,
                                  :conversation_template_id => conversation_id)
            item = {
                  :brand_id => company_id,
                  :user_id => user.id,
                  :operator_id => operator_id,
                  :channel_id => channel_id,
                  :conversation_template_id => conversation_id,
                  :status => customer_status.present? ? customer_status : 2,
                  :is_imported => imported
              }
              if insert_data.exclude?(item)
                  insert_data << item
              end
          end

          unless ShortLink.data_exists?(operator_id, channel_id, conversation_id, nil, user.id, false)
            item_short_link = {
              :key => ShortLink.generate_unique_key,
              :operator_id => operator_id,
              :operator_channel_id => channel_id,
              :conversation_template_id => conversation_id,
              :coupon_id => nil,
              :referral_user_id => user.id,
              :share => false
            }

            insert_short_link_data << item_short_link
          end
      end
      if insert_data.present?
          Customer.create(insert_data)
          result = true
      end
      if insert_short_link_data.present?
        ShortLink.create(insert_short_link_data)
      end
      result
  end

  def set_dynamics_dates_when_create
    current_date_time = self.created_at
    imported_date = self.is_imported != 0 ? current_date_time : nil
    changed_to_lead_date = self.status == 1 ? current_date_time : nil
    changed_to_customer_date = self.status == 2 ? current_date_time : nil
    changed_to_lost_date = self.status == 3 ? current_date_time : nil
    CustomerDynamics.create({
                              :customer_id => self.id,
                              :customer_status => self.status,
                              :operator_id => self.operator_id,
                              :created_date => current_date_time,
                              :imported_date => imported_date,
                              :changed_to_lead_date => changed_to_lead_date,
                              :changed_to_customer_date => changed_to_customer_date,
                              :changed_to_lost_date => changed_to_lost_date,
                            })
  end

  def update_customer_status(status = 1)
      Customer.where(user_id: self.user_id, operator_id:self.operator_id).update_all(status:status)
  end

  def set_dynamics_dates_when_update
    if self.changes[:status].present?
      current_date_time = DateTime.now
      customer_dynamics = CustomerDynamics.find_by_customer_id(self.id)
      unless customer_dynamics.present?
        customer_dynamics = CustomerDynamics.new
        customer_dynamics.customer_id = self.id
        customer_dynamics.operator_id = self.operator_id
      end
      customer_dynamics.customer_status = self.status
      if self.changes[:status][1] == 1
        customer_dynamics.changed_to_lead_date = current_date_time
        customer_dynamics.changed_to_customer_date = nil
        customer_dynamics.changed_to_lost_date = nil
      elsif self.changes[:status][1] == 2
        customer_dynamics.changed_to_customer_date = current_date_time
        customer_dynamics.changed_to_lead_date = nil
        customer_dynamics.changed_to_lost_date = nil
      else
        customer_dynamics.changed_to_lost_date = current_date_time
        customer_dynamics.changed_to_customer_date = nil
        customer_dynamics.changed_to_lead_date = nil
      end
      customer_dynamics.save
    end
  end

  def set_deleted_date
    customer_dynamics = CustomerDynamics.find_by_customer_id(self.id)
    unless customer_dynamics.present?
      customer_dynamics = CustomerDynamics.new
      customer_dynamics.customer_id = self.id
      customer_dynamics.operator_id = self.operator_id
      customer_dynamics.customer_status = self.status
    end
    customer_dynamics.deleted_date = DateTime.now
    customer_dynamics.save
  end

  def set_lead_date_when_create
    if self.status == 1
      self.set_lead_date = DateTime.now
    end
  end

  def set_lead_date_when_update
    if self.changes[:status].present? && !self.set_lead_date.present?
      self.set_lead_date_when_create
    end
  end

  def set_is_converted_customer
    if self.status == 2
      self.is_converted_customer = 1
    else
      self.is_converted_customer = 0
    end
  end

  def set_imported_as_status
    if self.is_imported == 1
      self.imported_as_status = self.status
    end
  end

  def get_lead_previously
    self.set_lead_date.present? && self.status == 2
  end

  def get_campaigns
    Channel.select('id, title').where(:id => self.channel_id)
  end
end
