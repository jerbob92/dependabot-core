# frozen_string_literal: true

require "nokogiri"

require "dependabot/dependency_file"
require "dependabot/maven/file_parser"
require "dependabot/registry_client"
require "dependabot/errors"

# For documentation, see:
# - http://maven.apache.org/pom.html#Repositories
# - http://maven.apache.org/guides/mini/guide-multiple-repositories.html
module Dependabot
  module Maven
    class FileParser
      class RepositoriesFinder
        require_relative "property_value_finder"
        # In theory we should check the artifact type and either look in
        # <repositories> or <pluginRepositories>. In practice it's unlikely
        # anyone makes this distinction.
        REPOSITORY_SELECTOR = "repositories > repository, " \
                              "pluginRepositories > pluginRepository"

        # The Central Repository is included in the Super POM, which is
        # always inherited from.
        CENTRAL_REPO_URL = "https://repo.maven.apache.org/maven2"
        SUPER_POM = { url: CENTRAL_REPO_URL, id: "central" }

        def initialize(dependency_files:, credentials: [], evaluate_properties: true)
          @dependency_files = dependency_files
          @credentials = credentials

          # We need the option not to evaluate properties so as not to have a
          # circular dependency between this class and the PropertyValueFinder
          # class
          @evaluate_properties = evaluate_properties
        end

        # Collect all repository URLs from this POM and its parents
        def repository_urls(pom:, exclude_inherited: false)
          entries = gather_repository_urls(pom: pom, exclude_inherited: exclude_inherited)
          ids = Set.new
          urls_from_credentials + entries.map do |entry|
            next if entry[:id] && ids.include?(entry[:id])

            ids.add(entry[:id]) unless entry[:id].nil?
            entry[:url]
          end.uniq.compact
        end

        private

        attr_reader :dependency_files

        def gather_repository_urls(pom:, exclude_inherited: false)
          repos_in_pom =
            Nokogiri::XML(pom.content).
            css(REPOSITORY_SELECTOR).
            map { |node| { url: node.at_css("url").content.strip, id: node.at_css("id").content.strip } }.
            reject { |entry| contains_property?(entry[:url]) && !evaluate_properties? }.
            select { |entry| entry[:url].start_with?("http") }.
            map { |entry| { url: evaluated_value(entry[:url], pom).gsub(%r{/$}, ""), id: entry[:id] } }

          return repos_in_pom + [SUPER_POM] if exclude_inherited

          urls_in_pom = repos_in_pom.map { |repo| repo[:url] }
          unless (parent = parent_pom(pom, urls_in_pom))
            return repos_in_pom + [SUPER_POM]
          end

          repos_in_pom + gather_repository_urls(pom: parent)
        end

        def evaluate_properties?
          @evaluate_properties
        end

        # rubocop:disable Metrics/PerceivedComplexity
        def parent_pom(pom, repo_urls)
          doc = Nokogiri::XML(pom.content)
          doc.remove_namespaces!
          group_id = doc.at_xpath("/project/parent/groupId")&.content&.strip
          artifact_id =
            doc.at_xpath("/project/parent/artifactId")&.content&.strip
          version = doc.at_xpath("/project/parent/version")&.content&.strip

          return unless group_id && artifact_id

          name = [group_id, artifact_id].join(":")

          return internal_dependency_poms[name] if internal_dependency_poms[name]

          return unless version && !version.include?(",")

          fetch_remote_parent_pom(group_id, artifact_id, version, repo_urls)
        end
        # rubocop:enable Metrics/PerceivedComplexity

        def internal_dependency_poms
          return @internal_dependency_poms if @internal_dependency_poms

          @internal_dependency_poms = {}
          dependency_files.each do |pom|
            doc = Nokogiri::XML(pom.content)
            group_id = doc.at_css("project > groupId") ||
                       doc.at_css("project > parent > groupId")
            artifact_id = doc.at_css("project > artifactId")

            next unless group_id && artifact_id

            dependency_name = [
              group_id.content.strip,
              artifact_id.content.strip
            ].join(":")

            @internal_dependency_poms[dependency_name] = pom
          end

          @internal_dependency_poms
        end

        def fetch_remote_parent_pom(group_id, artifact_id, version, repo_urls)
          (urls_from_credentials + repo_urls + [CENTRAL_REPO_URL]).uniq.each do |base_url|
            url = remote_pom_url(group_id, artifact_id, version, base_url)

            @maven_responses ||= {}
            @maven_responses[url] ||= Dependabot::RegistryClient.get(
              url: url,
              # We attempt to find dependencies in private repos before failing over to the CENTRAL_REPO_URL,
              # but this can burn a lot of a job's time against slow servers due to our `read_timeout` being 20 seconds.
              #
              # In order to avoid the overall job timing out, we only make one retry attempt
              options: { retry_limit: 1 }
            )
            next unless @maven_responses[url].status == 200
            next unless pom?(@maven_responses[url].body)

            dependency_file = DependencyFile.new(
              name: "remote_pom.xml",
              content: @maven_responses[url].body
            )

            return dependency_file
          rescue Excon::Error::Socket, Excon::Error::Timeout,
                 Excon::Error::TooManyRedirects, URI::InvalidURIError
            nil
          end

          # If a parent POM couldn't be found, return `nil`
          nil
        end

        def remote_pom_url(group_id, artifact_id, version, base_repo_url)
          "#{base_repo_url}/" \
            "#{group_id.tr('.', '/')}/#{artifact_id}/#{version}/" \
            "#{artifact_id}-#{version}.pom"
        end

        def urls_from_credentials
          @credentials.
            select { |cred| cred["type"] == "maven_repository" }.
            filter_map { |cred| cred["url"]&.strip&.gsub(%r{/$}, "") }
        end

        def contains_property?(value)
          value.match?(property_regex)
        end

        def evaluated_value(value, pom)
          return value unless contains_property?(value)

          property_name = value.match(property_regex).
                          named_captures.fetch("property")
          property_value = value_for_property(property_name, pom)

          value.gsub(property_regex, property_value)
        end

        def value_for_property(property_name, pom)
          value =
            property_value_finder.
            property_details(
              property_name: property_name,
              callsite_pom: pom
            )&.fetch(:value)

          return value if value

          msg = "Property not found: #{property_name}"
          raise DependencyFileNotEvaluatable, msg
        end

        # Cached, since this can makes calls to the registry (to get property
        # values from parent POMs)
        def property_value_finder
          @property_value_finder ||=
            PropertyValueFinder.new(dependency_files: dependency_files)
        end

        def property_regex
          Maven::FileParser::PROPERTY_REGEX
        end

        def pom?(content)
          !Nokogiri::XML(content).at_css("project > artifactId").nil?
        end
      end
    end
  end
end
