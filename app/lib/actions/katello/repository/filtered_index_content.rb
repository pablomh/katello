module Actions
  module Katello
    module Repository
      class FilteredIndexContent < Actions::EntryAction
        input_format do
          param :id, Integer
          param :filter
          param :import_upload_task
          param :content_type
          param :upload_actions
        end

        # rubocop:disable Metrics/MethodLength
        # rubocop:disable Metrics/CyclomaticComplexity
        # rubocop:disable Metrics/PerceivedComplexity
        # rubocop:disable Metrics/AbcSize
        def run
          repo = ::Katello::Repository.find(input[:id])
          if repo.docker?
            ::Katello::DockerManifest.import_for_repository(repo)
            ::Katello::DockerTag.import_for_repository(repo)
            ::Katello::DockerManifestList.import_for_repository(repo)
          elsif repo.file?
            ::Katello::FileUnit.import_for_repository(repo)
          elsif repo.generic?
            repo.repository_type.content_types_to_index.each do |type|
              type.model_class.import_for_repository(repo, content_type: type.content_type)
            end
          elsif repo.deb?
            index_filtered_units(repo, ::Katello::Deb, uploaded_unit_ids)
          elsif repo.yum?
            unit_class = (input[:content_type] == ::Katello::Srpm::CONTENT_TYPE) ? ::Katello::Srpm : ::Katello::Rpm
            index_filtered_units(repo, unit_class, uploaded_unit_ids)
          end
        end

        private

        def uploaded_unit_ids
          if input[:import_upload_task] && input[:import_upload_task][:content_unit_href]
            [input[:import_upload_task][:content_unit_href]]
          elsif input[:upload_actions]&.any? { |action| action.try(:[], "content_unit_href") }
            input[:upload_actions].filter_map { |action| action.try(:[], "content_unit_href") }
          else
            []
          end
        end

        # The upload only adds units; the pass leaves the index describing the whole version.
        def index_filtered_units(repo, unit_class, unit_ids)
          repo.index_whole_version do
            unit_class.import_all(unit_ids, repo, :filtered_indexing => true)
          end
          repo.update!(:last_indexed => DateTime.now)
        end
      end
    end
  end
end
