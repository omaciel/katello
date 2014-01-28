#
# Copyright 2013 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

module Katello
class PackageGroupFilter < Filter
  use_index_of Filter if Katello.config.use_elasticsearch

  CONTENT_TYPE = PackageGroup::CONTENT_TYPE

  before_create :set_parameters

  validates_with Validators::PackageGroupFilterParamsValidator, :attributes => :parameters
  def params_format
    { :units => [[:name, :inclusion, :created_at]] }
  end

  def generate_clauses(repo)
    ids = parameters[:units].collect do |unit|
      #{'name' => {"$regex" => unit[:name]}}
      unless unit[:name].blank?
        PackageGroup.search(unit[:name], 0, 0, [repo.pulp_id]).collect(&:package_group_id)
      end
    end
    ids.flatten!
    ids.compact!
    { "id" => { "$in" => ids } } unless ids.empty?
  end

  private

  def set_parameters
    parameters[:units].each do |unit|
      unit[:created_at] = Time.zone.now
      unit[:inclusion] = false unless unit.has_key?(:inclusion)
    end if !parameters.blank? && parameters.has_key?(:units)
  end

end
end
