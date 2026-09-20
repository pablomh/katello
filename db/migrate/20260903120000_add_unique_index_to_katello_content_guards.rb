class AddUniqueIndexToKatelloContentGuards < ActiveRecord::Migration[6.1]
  def up
    remove_duplicate_content_guards

    add_index :katello_content_guards,
              :name,
              :unique => true,
              :name => :index_katello_content_guards_on_name
  end

  def down
    remove_index :katello_content_guards,
                 :name => :index_katello_content_guards_on_name
  end

  private

  # The original :unique => true on this column (20200407171926_create_content_guard.rb)
  # was silently ignored by create_table's column DSL, so duplicate rows may have
  # accumulated under concurrent refresh() calls. Keep the earliest row per name.
  def remove_duplicate_content_guards
    Katello::Pulp3::ContentGuard.unscoped.group(:name).having('COUNT(*) > 1').pluck(:name).each do |name|
      ids = Katello::Pulp3::ContentGuard.unscoped.where(:name => name).order(:id).pluck(:id)
      Katello::Pulp3::ContentGuard.unscoped.where(:id => ids.drop(1)).delete_all
    end
  end
end
