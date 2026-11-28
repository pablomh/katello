module Katello
  class ContentIndex < Katello::Model
    # Repositories holding the same Pulp version share one index, which is never
    # mutated while another repository references it.
    has_many :content_index_rpms, :dependent => :delete_all, :inverse_of => :content_index
    has_many :content_index_errata, :dependent => :delete_all, :inverse_of => :content_index
    has_many :content_index_srpms, :dependent => :delete_all, :inverse_of => :content_index
    has_many :content_index_module_streams, :dependent => :delete_all, :inverse_of => :content_index
    has_many :content_index_debs, :dependent => :delete_all, :inverse_of => :content_index
    has_many :content_index_file_units, :dependent => :delete_all, :inverse_of => :content_index
    has_many :content_index_package_groups, :dependent => :delete_all, :inverse_of => :content_index
    has_many :content_index_ansible_collections, :dependent => :delete_all, :inverse_of => :content_index
    has_many :content_index_generic_content_units, :dependent => :delete_all, :inverse_of => :content_index

    has_many :repositories, :class_name => 'Katello::Repository', :inverse_of => :content_index, :dependent => :nullify

    validates :version_href, :presence => true, :uniqueness => true

    def self.for_version(version_href)
      # A savepoint keeps the enclosing transaction usable when a competing insert
      # loses the race and PostgreSQL aborts the statement.
      transaction(:requires_new => true) { find_or_create_by!(:version_href => version_href) }
    rescue ActiveRecord::RecordNotUnique
      find_by!(:version_href => version_href)
    rescue ActiveRecord::RecordInvalid => e
      # The uniqueness validator raises this when the competing row was already
      # visible; any other validation failure is real.
      raise unless e.record.is_a?(ContentIndex) && e.record.errors.of_kind?(:version_href, :taken)

      find_by!(:version_href => version_href)
    end

    # Copy-on-write: nobody but this repository may depend on the index rows.
    def private_to?(repository)
      repositories.where.not(:id => repository).none?
    end

    # NOT IN over a subquery with NULLs matches nothing, so ask with NOT EXISTS.
    def self.orphaned
      where.missing(:repositories)
    end
  end
end
