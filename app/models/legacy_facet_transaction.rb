class LegacyFacetTransaction < ApplicationRecord
  include LegacyModel
  
  self.table_name = "contract_transactions"
  
  has_one :transaction_receipt, foreign_key: :transaction_hash, primary_key: :transaction_hash, inverse_of: :legacy_facet_transaction, class_name: "LegacyFacetTransactionReceipt"
end
