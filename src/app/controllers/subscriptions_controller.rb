#
# Copyright 2011 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.
require 'ostruct'

class SubscriptionsController < ApplicationController

  before_filter :find_subscription, :except=>[:index, :items]
  before_filter :authorize
  before_filter :setup_options, :only=>[:index, :items]

  # two pane columns and mapping for sortable fields
  COLUMNS = {'name' => 'name_sort'}

  def rules
    read_org = lambda{current_organization && current_organization.readable?}
    {
      :index => read_org,
      :items => read_org,
      :show => lambda{true},
      :edit => lambda{true},
      :products => lambda{true}
    }
  end


  def index
  end

  def items
    order = split_order(params[:order])
    search = params[:search]
    offset = params[:offset]
    filters = {}

    # TODO: Call as before_filter?
    find_subscriptions

    if offset
      render :text => "" and return if @subscriptions.empty?

      #options = {:list_partial => 'subscriptions/list_subscriptions', :accessor => "product_id", :name => controller_display_name}
      render_panel_items(@subscriptions, @panel_options, nil, offset)
    else
      @subscriptions = @subscriptions[0..current_user.page_size]

      #options = {:list_partial => 'subscriptions/list_subscriptions', :accessor => "product_id", :name => controller_display_name}
      render_panel_items(@subscriptions, @panel_options, nil, offset)
    end

    #render_panel_direct(Product, @panel_options, search, params[:offset], order,
    #                    {:filter=>filters, :load=>true})
  end

  def edit
    render :partial => "edit", :layout => "tupane_layout", :locals => {:subscription => @subscription, :editable => false, :name => controller_display_name}
  end

  def show
    render :partial=>"subscriptions/list_subscription_show", :locals=>{:item=>@subscription, :accessor=>"product_id", :columns => COLUMNS.keys, :noblock => 1}
  end

  def products
    render :partial=>"products", :layout => "tupane_layout", :locals=>{:subscription=>@subscription, :editable => false, :name => controller_display_name}
  end

  private

  def split_order order
    if order
      order.split
    else
      [:name_sort, "ASC"]
    end
  end

  def find_subscription
    product = Product.find(params[:id])
    @subscription = populate_subscription product
  end

  def find_subscriptions
    pools = Candlepin::Owner.pools current_organization.cp_key
    products = []
    pools.each do |pool|
      # Bonus pools have their sourceEntitlement set
      # TODO: Does the count of the parent pool get its quantity updated?
      next if pool['sourceEntitlement'] != nil

      product = Product.where(:cp_id => pool['productId']).first
      products << product
    end

    @subscriptions = products
  end

  # Package up subscription details for consumption by view layer
  def populate_subscription(product)

    cp_pool = Candlepin::Owner.pools(current_organization.cp_key, {:product => product.cp_id}).first
    cp_product = Candlepin::Product.get(product.cp_id).first

    subscription = OpenStruct.new cp_pool
    #subscription.consumed_stats = converted_stats
    subscription.product = cp_product
    subscription.startDate = Date.parse(subscription.startDate)
    subscription.endDate = Date.parse(subscription.endDate)

    # Other interesting attributes for easier access
    subscription.machine_type = ''
    subscription.support_level = ''
    cp_product['attributes'].each do |attr|
      if attr['name'] == 'virt_only'
        if attr['value'] == 'true'
          subscription.machine_type = _('Virtual')
        elsif attr['value'] == 'false'
          subscription.machine_type = _('Physical')
        end
      elsif attr['name'] == 'support_level'
        subscription.support_level = attr['value']
      elsif attr['name'] == 'arch'
        subscription.arch = attr['value']
      end
    end

    subscription
  end

=begin
  # Reformat the subscriptions from our API to a format that the headpin HAML expects
  def reformat_subscriptions(all_subs)
    subscriptions = []
    org_stats = Candlepin::Owner.statistics current_organization.cp_key
    converted_stats = []
    org_stats.each do |stat|
      converted_stats << OpenStruct.new(stat)
    end
    all_subs.each do |sub|
      product = Product.where(:cp_id =>sub["productId"]).first
      converted_product = OpenStruct.new
      converted_product.product_id = product.id
      converted_product.cp_id = sub["productId"]
      converted_product.support_level = product.support_level
      converted_product.arch = product.arch
      # Convert to OpenStruct so we can access fields with dot notation
      # in the haml. This reduces the code changes we pull in from headpin
      converted_sub = OpenStruct.new(sub)
      converted_sub.consumed_stats = converted_stats
      converted_sub.product = converted_product
      converted_sub.startDate = Date.parse(converted_sub.startDate)
      converted_sub.endDate = Date.parse(converted_sub.endDate)

      # Other interesting attributes
      converted_sub.machine_type = ''
      converted_sub.attributes.each do |attr|
        if attr['name'] == 'virt_only'
          if attr['value'] == 'true'
            converted_sub.machine_type = _('Virtual')
          elsif attr['value'] == 'false'
            converted_sub.machine_type = _('Physical')
          end
        end
      end
      #converted_sub.attributes = OpenStruct.new(converted_sub.attributes) if !converted_sub.attributes.nil?
      #converted_sub.productAttributes = OpenStruct.new(converted_sub.productAttributes) if !converted_sub.productAttributes.nil?
      subscriptions << converted_sub if !subscriptions.include? converted_sub
    end
    subscriptions
  end
=end

  def setup_options
    @panel_options = { :title => _('Subscriptions'),
                      :col => ["name"],
                      :titles => [_("Name")],
                      :custom_rows => true,
                      :enable_create => false,
                      :enable_sort => true,
                      :name => controller_display_name,
                      :list_partial => 'subscriptions/list_subscriptions',
                      :ajax_load  => true,
                      :ajax_scroll => items_subscriptions_path(),
                      :actions => nil,
                      :search_class => Product
                      }
  end

  def controller_display_name
    return 'subscription'
  end

end
