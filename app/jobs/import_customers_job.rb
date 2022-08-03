class ImportCustomersJob < ApplicationJob
  queue_as :default

  def perform(company_id, operator_id, channel_id, conversation_id, inviter_id, chunk, customer_status)
    Customer.import_data(company_id, operator_id, channel_id, conversation_id, inviter_id, chunk, customer_status)
  end
end
