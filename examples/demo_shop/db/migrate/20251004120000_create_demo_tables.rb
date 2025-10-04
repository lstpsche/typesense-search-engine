# frozen_string_literal: true

# Create minimal demo tables for the example app.
class CreateDemoTables < ActiveRecord::Migration[7.0]
  def change
    create_table :brands do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :products do |t|
      t.string  :name, null: false
      t.text    :description
      t.integer :price_cents, null: false, default: 0
      t.string  :category
      t.references :brand, null: false, foreign_key: true
      t.timestamps
    end

    create_table :authors do |t|
      t.string :first_name
      t.string :last_name
      t.timestamps
    end

    create_table :books do |t|
      t.string :title, null: false
      t.references :author, null: false, foreign_key: true
      t.timestamps
    end

    create_table :orders do |t|
      t.integer :total_cents, null: false, default: 0
      t.timestamps
    end

    create_table :order_items do |t|
      t.references :order, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.integer :quantity, null: false, default: 1
      t.integer :price_cents, null: false, default: 0
      t.timestamps
    end
  end
end
