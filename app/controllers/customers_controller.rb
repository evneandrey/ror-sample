class CustomersController < ApplicationController
  before_action :authenticate_user!
  before_action :current_user_data
  before_action :find_operator, only: %i[index create_vouchers print export deduction]
  before_action :find_brand_id, only: %i[index create_vouchers print export]
  before_action :find_customers, only: %i[index create_vouchers print]
  before_action :find_all_customers, only: %i[export]

  def index
      authorize Customer
      @operators = Operator.all if current_or_guest_user.admin && params[:operator_id].blank?
  end

  def destroy
    authorize Customer
    if current_or_guest_user.admin? && params[:brand_id].present? && (brand = Brand.find(params[:brand_id])) && brand.present?
      if params[:id] == "list"
        if params[:operator_id].present? && (operator = Operator.find(params[:operator_id])) && operator.present?
          CompanyService.delete_company_customers_list(company_id: brand.id, operator_id: operator.id)
        end
      else
        CompanyService.delete_company_customers(customer_id: params[:id], company_id: brand.id)
      end
    else
      head :forbidden
    end
  end

  def print
    response.headers["Cache-Control"] = "no-cache, no-store"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "Mon, 01 Jan 1990 00:00:00 GMT"
    authorize Customer
    if @customers.present?
      date_from = @customers.present? ? DateTime.parse(@customers.map{|h| h[:createdAt]}.min).strftime("%Y") : DateTime.now.strftime("%Y")
      date_to = @customers.present? ? DateTime.parse(@customers.map{|h| h[:createdAt]}.max).strftime("%Y") : DateTime.now.strftime("%Y")
      @summary = Customer.for_print_data(@customers, date_from, date_to)
      return render :partial => "customers/print"
    end
    redirect_to customers_path(:operator_id => params[:operator_id])
  end

  def export
    # authorize @account
    authorize Customer
    if @customers.present?
      link_host = Rails.env.production? ? "https://example.com/" : root_url
      customers = helpers.export_data(@customers, @operator, link_host)
      @summary = Customer.for_export_data(customers)
      return send_data @summary, :filename => "customers-#{Date.today}.csv"
    end
    redirect_to customers_path(:operator_id => params[:operator_id])
  end

  def register_user_on_operators
    @operators = Operator.all
    @user = current_or_guest_user
  end

  def register_multiple_users_on_operators
    authorize Customer
    @user = current_or_guest_user
    respond_to do |format|
      if valid_form_params?
        operator_id = params[:operator_id]
        channel_id = params[:channel_id]
        first_name = params[:first_name]
        last_name = params[:last_name]
        conversation_id = params[:conversation_template_id]
        company_id = Operator.find(params[:operator_id]).brands.first
        CompanyService.create_company_customers(
            company_id: company_id.id,
            emails: params[:invited_emails],
            operator_id: operator_id,
            channel_id: channel_id,
            conversation_id: conversation_id,
            inviter_id: @user.id,
            status: 2,
            first_name: first_name,
            last_name: last_name
        )
        format.html { redirect_to customers_path }
      else
        @operators = Operator.all
        format.html { render :register_user_on_operators }
        format.json { render json: @user.errors, status: :unprocessable_entity }
      end
    end
  end

  def add_user_to_list
      authorize Customer
      @user = current_or_guest_user
      respond_to do |format|
          if exec_params_for_add_user_to_list_and_valid?
              CompanyService.create_company_customers(
                  company_id: @brand.id,
                  emails: params[:user_email],
                  operator_id: @operator.id,
                  channel_id: @channel.id,
                  conversation_id: @template.id,
                  inviter_id: @user.id,
                  status: 1)
              invited = User.where(:email => params[:user_email]).first
              invited.options = { "balances": {} }
              invited.invited_by_id = @inviter.id
              invited.save!
              reward = reward_for_invited_user
              RewardCredit.create(operator: @operator, user: invited, currency_id: reward.currency, value: reward.value)
              if current_or_guest_user.admin?
                format.html { redirect_to customers_path(:operator_id => @operator.id) }
              else
                format.html { redirect_to customers_path }
              end
          else
            if current_or_guest_user.admin?
              format.html { redirect_to customers_path(:operator_id => @operator.id), flash: { add_user_to_list_errors: @user.errors} }
            else
              format.html { redirect_to customers_path, flash: { add_user_to_list_errors: @user.errors} }
            end
              format.json { render json: @user.errors, status: :unprocessable_entity }
          end
      end
  end

  def update_customer_status
    authorize Customer

    if params[:user_id] && params[:brand_id] && params[:status]
      CompanyService.update_company_customers(company_id: params[:brand_id], user_id: params[:user_id], status: params[:status])
      customer = Customer.find_by(:id => params[:customer_id])
      if customer.present?
        helpers.redeem_customer_coupons(customer)
        helpers.customer_notification(customer) if params[:status] == "2"
      end
    end
  end

  def create_vouchers
    authorize Customer
    new_customer_vouchers = Customer.generate_vouchers(@operator, params[:user_ids], params[:product_id], current_or_guest_user.admin)
    respond_to do |format|
      format.csv { send_data create_vouchers_csv(new_customer_vouchers), filename: "create-vouchers-#{Date.today}.csv" }
    end
  end

  def deduction
    authorize Customer
    Customer.deduction(@operator, params[:user_ids])
  end

  def import_customers
    authorize Customer
    @customer = Customer.new
    @customer.is_valid_import_file customer_params[:file]
    operator = Operator.find_by(:id => customer_params[:operator_id])
    brand = operator&.brands&.first
    channel = operator&.active_channel
    template = channel.present? ? channel.conversation_templates.first : nil
    @customer.errors[:operator_id] << "Field \"operator_id\" isn't correct" if operator.blank?
    @customer.errors[:operator_id] << "the operator must have a relationship with at least one brand" if brand.blank?
    @customer.errors[:operator_id] << "the operator must have at least one default channel" if channel.blank?
    @customer.errors[:operator_id] << "the default channel must have at least one conversation template" if template.blank?

    if @customer.errors.any?.blank?
      if @customer.importing_rows.length == 1 #if customers <= 500 (live execution)
        Customer.import_data(brand.id, operator.id, channel.id, template.id, current_or_guest_user.id, @customer.importing_rows.first, 2)
      else #if customers > 500 (background tasks)
        @customer.importing_rows.each do |customer_chunk|
          ImportCustomersJob.perform_later(brand.id, operator.id, channel.id, template.id, current_or_guest_user.id, customer_chunk, 2)
        end
      end
      return redirect_to customers_path(:operator_id => operator.id), flash: { actionMessage: text("Customers import was successfully started!") }
    end
    redirect_to customers_path(:operator_id => operator&.id), flash: { actionMessage: text("Something was wrong!"), errors: @customer.errors.as_json }
  end

  private

  def customer_params
    params.require(:customer).permit(:operator_id, :file)
  end

  def find_customers
    @customers = []
    @total_customers = 0
    @total_leads = 0
    @total_lost = 0
    @total_customer = 0
    @active_channel = @operator.active_channel if @operator
    if @brand_id.present?
      sort = params[:sort].present? ? params[:sort] : 'DESC'
      search = params[:search].present? ? params[:search] : ''
      @customers_data = CompanyService.find_company_customers(@brand_id, sort, search, params[:operator_id], (params[:page] || 1), (params[:qty] || 10))
      @customers = @customers_data['data']
      @customers.each.with_index do |c, k|
        @customers[k][:firstMessageDate] = helpers.date_fix_offset(c[:firstMessageDate])
        @customers[k][:lastMessageDate] = helpers.date_fix_offset(c[:lastMessageDate])
      end
      @total_customers = @customers_data['totalEntity'] || 0
      @total_leads = @customers_data['totalLead'] || 0
      @total_lost = @customers_data['totalLost'] || 0
      @total_customer = @customers_data['totalCustomer'] || 0
    end
    begin
      @customers = [] if  @customers["code"] == "unknown"
    rescue
      # nothing
    end
  end

  def find_all_customers
    @customers = Customer.includes(:user)
                         .where(brands_users: { operator_id: @operator.id, status: [1, 2, 3] })
                         .where.not(brands_users: { user_id: nil })
                         .order(user_id: :desc)
  end

  def create_vouchers_csv(customer_list = {})
    CSV.generate do |csv|
      if @customers.size > 0
        csv << ['Value','FirstName','LastName','AddressLine1','AddressLine2','City_Address3','State_Province_Address4','Zip_PostalCode_Address5','CountryCode','EmailAddress','Delivery','ClientID','ProgramID','ProductID','DistributionMessage','RedemptionMessage','CarrierMessage1','CarrierMessage2','CarrierMessage3','4thLineEmbossing','Language','Participant ID','Distribution Template','EndClientId','ClientData1','ClientData2','ClientData3','ClientData4','ClientData5','ClientData6','ClientData7','ClientData8','ClientData9','ClientData10']
        @customers.each do |c|
          csv << generate_vouchers_csv_row(c, customer_list[c[:customerId]]) if customer_list.present? && customer_list.keys.include?(c[:customerId])
        end
      end
    end
  end

  def generate_vouchers_csv_row customer, value
    user = User.find(customer[:id])
    csv_prepared_data = Rails.application.config.csv_prepared_data
    [value.round(2).to_f, customer[:firstName], customer[:lastName], nil, nil, nil, nil, nil, user.country_code, customer[:email], csv_prepared_data[:delivery], csv_prepared_data[:clientId], csv_prepared_data[:programId], csv_prepared_data[:productId], nil, nil, nil, nil, nil, nil, nil, nil, csv_prepared_data[:distributionTemplate], csv_prepared_data[:endClientId], nil, nil, nil, nil, nil, nil, nil, nil, nil, nil]
  end

  def exec_params_for_add_user_to_list_and_valid?
      if params[:brand_id].blank?
          @user.errors[:brand_id] << "Brand id must be set"
          return false
      end
      @brand = Brand.find(params[:brand_id])
      if params[:brand_id].blank?
          @user.errors[:brand_id] << "Brand is not exists"
          return false
      end
      @operator = @brand.operators.first
      if @operator.blank?
          @user.errors[:operator_id] << "Operator is not exists"
          return false
      end
      @channel = @operator.channels.first
      if @channel.blank?
          @user.errors[:channel_id] << "Channel is not exists"
          return false
      end
      @template = @channel.conversation_templates.first
      if @template.blank?
          @user.errors[:template_id] << "Conversation template is not exists"
          return false
      end
      if params[:inviter_mail].blank?
          @user.errors[:inviter_mail] << "Inviter mail must be set"
          return false
      end
      if params[:user_email].blank?
          @user.errors[:user_email] << "User email must be set"
          return false
      end
      unless /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i =~ params[:inviter_mail]
          @user.errors[:inviter_mail] << "Inviter mail is not a valid email"
          return false
      end
      unless /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i =~ params[:user_email]
          @user.errors[:user_email] << "User email is not a valid email"
          return false
      end
      @inviter = User.where(:email => params[:inviter_mail]).first
      if @inviter.blank?
          @user.errors[:inviter_mail] << "E-mail is not exist"
          return false
      end
      @referral = BrandsUser.joins(:user).where("users.email = ?", params[:user_email]).where(:brand_id => @brand.id, :operator_id => @operator.id, :channel_id => @channel.id).first
      if @referral.present?
          @user.errors[:user_email] << "E-mail already exist"
          return false
      end
      true
  end

  def valid_form_params?
    if params[:invited_emails].blank?
      @user.errors[:email] << "E-mail must be set"
    end
    if params[:operator_id].blank?
      @user.errors[:operator] << "Operator must be set"
    end
    if params[:operator_id].present? && Operator.find(params[:operator_id]).brands.blank?
      @user.errors[:operator] << "Operator must have brand"
    end
    if params[:invited_emails].present?
      params[:invited_emails].split(',').each do |email|
        unless /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i =~ email
          @user.errors[:email] << "E-mail is not a valid"
          break
        end
      end
    end
    !@user.errors.any?
  end

  def best_currency(user, operator = nil)
      currency = user.best_currency
      if operator.present?
        operator_currencies = Currency.where(:operator => operator).collect {|c| c.key }
        unless operator_currencies.include? currency
          currency = operator_currencies.first if operator_currencies.present?
        end
      end
      currency = Currency.first.key if currency.blank?
      currency
  end

  def reward_for_invited_user
      currency = Currency.find_by(:key => best_currency(@user, @operator))
      this_operator = currency.operator
      nok_reward_value = Money.new(params[:reward], "NOK").to_f * this_operator.reward_shares.first.share_own_reward_other_ad.to_f
      Reward.new(
          currency: currency.id,
          value: (currency.conversion_rate * nok_reward_value).to_i,
          user_id: @operator.user_id,
          ranking_id: @operator.ranking_id
      )
  end

  def find_operator
    @operator =
      if current_or_guest_user.admin && params[:operator_id].present?
        Operator.find_by_id(params[:operator_id])
      else
        if current_or_guest_user.record_permissions.present?
          brand_id = current_or_guest_user.record_permissions.first.record_id
          Brand.find_by_id(brand_id).operators.first
        end
      end
  end

  def find_brand_id
    @brand_id =
      if current_or_guest_user.admin && params[:operator_id].present?
        find_operator.brand_ids.first
      else
        if current_or_guest_user.record_permissions.present?
          current_or_guest_user.record_permissions.first.record_id
        end
      end
  end
end
