# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/python/file_updater"
require "dependabot/shared_helpers"
require_common_spec "file_updaters/shared_examples_for_file_updaters"

RSpec.describe Dependabot::Python::FileUpdater do
  it_behaves_like "a dependency file updater"

  let(:updater) do
    described_class.new(
      dependency_files: dependency_files,
      dependencies: [dependency],
      credentials: credentials
    )
  end
  let(:dependency_files) { [requirements] }
  let(:requirements) do
    Dependabot::DependencyFile.new(
      content: fixture("requirements", requirements_fixture_name),
      name: "requirements.txt"
    )
  end
  let(:requirements_fixture_name) { "version_specified.txt" }
  let(:dependency) do
    Dependabot::Dependency.new(
      name: "psycopg2",
      version: "2.8.1",
      requirements: [{
        file: "requirements.txt",
        requirement: "==2.8.1",
        groups: [],
        source: nil
      }],
      previous_requirements: [{
        file: "requirements.txt",
        requirement: "==2.6.1",
        groups: [],
        source: nil
      }],
      package_manager: "pip"
    )
  end
  let(:credentials) do
    [{
      "type" => "git_source",
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => "token"
    }]
  end
  let(:tmp_path) { Dependabot::Utils::BUMP_TMP_DIR_PATH }

  before { FileUtils.mkdir_p(tmp_path) }

  describe "#updated_dependency_files" do
    subject(:updated_files) { updater.updated_dependency_files }

    context "with a relative project path" do
      let(:dependency_files) { project_dependency_files("poetry/relative_path") }

      let(:dependency) do
        Dependabot::Dependency.new(
          name: "mypy",
          version: "0.910",
          previous_version: "0.812",
          requirements: [{
            file: "pyproject.toml",
            requirement: "^0.910",
            groups: ["dev-dependencies"],
            source: nil
          }],
          previous_requirements: [{
            file: "pyproject.toml",
            requirement: "^0.812",
            groups: ["dev-dependencies"],
            source: nil
          }],
          package_manager: "pip"
        )
      end

      specify { expect(updated_files.count).to eq(2) }
    end

    context "with a Pipfile and Pipfile.lock" do
      let(:dependency_files) { [pipfile, lockfile] }
      let(:pipfile) do
        Dependabot::DependencyFile.new(
          name: "Pipfile",
          content: fixture("pipfiles", "version_not_specified")
        )
      end
      let(:lockfile) do
        Dependabot::DependencyFile.new(
          name: "Pipfile.lock",
          content: fixture("lockfiles", "version_not_specified.lock")
        )
      end

      let(:dependency) do
        Dependabot::Dependency.new(
          name: "requests",
          version: "2.18.4",
          previous_version: "2.18.0",
          package_manager: "pip",
          requirements: [{
            requirement: "*",
            file: "Pipfile",
            source: nil,
            groups: ["default"]
          }],
          previous_requirements: [{
            requirement: "*",
            file: "Pipfile",
            source: nil,
            groups: ["default"]
          }]
        )
      end

      it "delegates to PipfileFileUpdater" do
        expect(described_class::PipfileFileUpdater).
          to receive(:new).and_call_original
        expect { updated_files }.to_not(change { Dir.entries(tmp_path) })
        updated_files.each { |f| expect(f).to be_a(Dependabot::DependencyFile) }
      end
    end

    context "with just a Pipfile" do
      let(:dependency_files) { [pipfile, requirements] }
      let(:pipfile) do
        Dependabot::DependencyFile.new(
          name: "Pipfile",
          content: fixture("pipfiles", "exact_version")
        )
      end

      let(:dependency) do
        Dependabot::Dependency.new(
          name: "requests",
          version: "2.18.4",
          previous_version: "2.18.0",
          package_manager: "pip",
          requirements: [{
            requirement: "==2.18.4",
            file: "Pipfile",
            source: nil,
            groups: ["default"]
          }],
          previous_requirements: [{
            requirement: "==2.18.0",
            file: "Pipfile",
            source: nil,
            groups: ["default"]
          }]
        )
      end

      it "delegates to PipfileFileUpdater" do
        expect(described_class::PipfileFileUpdater).
          to receive(:new).and_call_original
        expect { updated_files }.to_not(change { Dir.entries(tmp_path) })
        updated_files.each { |f| expect(f).to be_a(Dependabot::DependencyFile) }
      end
    end

    context "with multiple manifests declaring the same dependency" do
      let(:dependency_files) { [pyproject, requirements] }
      let(:pyproject) do
        Dependabot::DependencyFile.new(
          name: "pyproject.toml",
          content: fixture("pyproject_files", "pytest.toml")
        )
      end
      let(:requirements_fixture_name) { "version_specified.txt" }

      let(:dependency) do
        Dependabot::Dependency.new(
          name: "pytest",
          version: "3.5.0",
          previous_version: "3.4.0",
          package_manager: "pip",
          requirements: [{
            requirement: "3.5.0",
            file: "pyproject.toml",
            groups: ["dependencies"],
            source: nil
          }, {
            requirement: "==3.5.0",
            file: "requirements.txt",
            groups: ["dependencies"],
            source: nil
          }],
          previous_requirements: [{
            requirement: "3.4.0",
            file: "pyproject.toml",
            groups: ["dependencies"],
            source: nil
          }, {
            requirement: "==3.4.0",
            file: "requirements.txt",
            groups: ["dependencies"],
            source: nil
          }]
        )
      end

      # Perhaps ideally we'd replace both, but this is where we're at right now.
      # See https://github.com/dependabot/dependabot-core/pull/4969
      it "replaces one of the outdated dependencies" do
        expect(updated_files.length).to eq(1)
        expect(updated_files[0].content).to include('pytest = "3.5.0"')
      end
    end

    context "with a pyproject.toml and pyproject.lock" do
      let(:dependency_files) { [pyproject, lockfile] }
      let(:pyproject) do
        Dependabot::DependencyFile.new(
          name: "pyproject.toml",
          content:
            fixture("pyproject_files", "version_not_specified.toml")
        )
      end
      let(:lockfile) do
        Dependabot::DependencyFile.new(
          name: "pyproject.lock",
          content:
            fixture("pyproject_locks", "version_not_specified.lock")
        )
      end

      let(:dependency) do
        Dependabot::Dependency.new(
          name: "requests",
          version: "2.18.4",
          previous_version: "2.18.0",
          package_manager: "pip",
          requirements: [{
            requirement: "*",
            file: "pyproject.toml",
            source: nil,
            groups: ["default"]
          }],
          previous_requirements: [{
            requirement: "*",
            file: "pyproject.toml",
            source: nil,
            groups: ["default"]
          }]
        )
      end

      it "delegates to PoetryFileUpdater" do
        expect(described_class::PoetryFileUpdater).
          to receive(:new).and_call_original
        expect { updated_files }.to_not(change { Dir.entries(tmp_path) })
        updated_files.each { |f| expect(f).to be_a(Dependabot::DependencyFile) }
      end
    end

    context "with a pip-compile file" do
      let(:dependency_files) { [manifest_file, generated_file] }
      let(:manifest_file) do
        Dependabot::DependencyFile.new(
          name: "requirements/test.in",
          content: fixture("pip_compile_files", "unpinned.in")
        )
      end
      let(:generated_file) do
        Dependabot::DependencyFile.new(
          name: "requirements/test.txt",
          content: fixture("requirements", "pip_compile_unpinned.txt")
        )
      end
      let(:dependency) do
        Dependabot::Dependency.new(
          name: "psycopg2",
          version: "2.8.1",
          requirements: [{
            file: "requirements/test.in",
            requirement: "==2.8.1",
            groups: [],
            source: nil
          }],
          previous_requirements: [{
            file: "requirements/test.in",
            requirement: "==2.7.1",
            groups: [],
            source: nil
          }],
          package_manager: "pip"
        )
      end

      it "delegates to PipCompileFileUpdater" do
        dummy_updater =
          instance_double(described_class::PipCompileFileUpdater)
        allow(described_class::PipCompileFileUpdater).to receive(:new).
          and_return(dummy_updater)
        expect(dummy_updater).
          to receive(:updated_dependency_files).
          and_return([OpenStruct.new(name: "updated files")])
        expect(updater.updated_dependency_files).
          to eq([OpenStruct.new(name: "updated files")])
      end

      context "and a requirements.txt that specifies a subdependency" do
        let(:dependency_files) { [manifest_file, generated_file, requirements] }
        let(:manifest_fixture_name) { "requests.in" }
        let(:generated_fixture_name) { "pip_compile_requests.txt" }
        let(:requirements_fixture_name) { "urllib.txt" }
        let(:pypi_url) { "https://pypi.org/simple/urllib/" }

        let(:dependency_name) { "urllib" }
        let(:dependency_version) { "1.22" }
        let(:dependency_requirements) do
          [{
            file: "requirements.txt",
            requirement: nil,
            groups: [],
            source: nil
          }]
        end

        it "delegates to PipCompileFileUpdater" do
          dummy_updater =
            instance_double(described_class::PipCompileFileUpdater)
          allow(described_class::PipCompileFileUpdater).to receive(:new).
            and_return(dummy_updater)
          expect(dummy_updater).
            to receive(:updated_dependency_files).
            and_return([OpenStruct.new(name: "updated files")])
          expect(updater.updated_dependency_files).
            to eq([OpenStruct.new(name: "updated files")])
        end
      end
    end

    describe "with no Pipfile or pip-compile files" do
      let(:dependency_files) { [requirements] }

      it "delegates to RequirementFileUpdater" do
        expect(described_class::RequirementFileUpdater).
          to receive(:new).and_call_original
        expect { updated_files }.to_not(change { Dir.entries(tmp_path) })
        updated_files.each { |f| expect(f).to be_a(Dependabot::DependencyFile) }
      end
    end
  end
end
