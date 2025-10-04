# frozen_string_literal: true

module Docs
  # Deterministic seed data for the demo shop.
  #
  # Usage:
  #   bin/rails runner "Docs::SeedDemo.run"
  class SeedDemo
    def self.run
      new.run
    end

    def run
      srand(1234)
      ActiveRecord::Base.transaction do
        reset!
        create_brands!
        create_products!
        create_authors_and_books!
        create_orders!
      end
      puts 'Seed completed.'
    end

    private

    BRANDS = %w[
      Acme Nova Luma Apex Orion Helix Nimbus Titan Vertex Quantum Radiant
    ].freeze

    CATEGORIES = %w[books toys gadgets apparel home office sports games food misc].freeze

    def reset!
      OrderItem.delete_all
      Order.delete_all
      Book.delete_all
      Author.delete_all
      Product.delete_all
      Brand.delete_all
    end

    def create_brands!
      BRANDS.each { |name| Brand.create!(name: name) }
    end

    def create_products!
      brands = Brand.order(:id).to_a
      rng = Random.new(42)
      50.times do |i|
        brand = brands[i % brands.size]
        Product.create!(
          name: "Product #{i + 1}",
          description: "Demo product ##{i + 1} in category",
          price_cents: rng.rand(500..50_00),
          category: CATEGORIES[i % CATEGORIES.size],
          brand: brand
        )
      end
    end

    def create_authors_and_books!
      authors = [
        %w[Joanne Rowling],
        %w[George Orwell],
        %w[Isaac Asimov],
        %w[Jane Austen],
        %w[Mark Twain],
        %w[Agatha Christie]
      ].map { |(f, l)| Author.create!(first_name: f, last_name: l) }

      rng = Random.new(7)
      20.times do |i|
        a = authors[i % authors.size]
        Book.create!(title: "Book #{i + 1}", author: a, created_at: Time.now - rng.rand(1..10).days)
      end
    end

    def create_orders!
      rng = Random.new(1337)
      prods = Product.order(:id).to_a
      20.times do
        order = Order.create!(total_cents: 0)
        items_count = rng.rand(1..3)
        total = 0
        items_count.times do
          p = prods[rng.rand(0...prods.size)]
          qty = rng.rand(1..2)
          price = p.price_cents
          OrderItem.create!(order: order, product: p, quantity: qty, price_cents: price)
          total += qty * price
        end
        order.update!(total_cents: total)
      end
    end
  end
end
