#
# Copyright 2014 Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module Omnibus
  # Builds a Mac OS X "product" package (.pkg extension)
  #
  # Mac OS X packages are built in two stages. First, files are packaged up
  # into one or more "component" .pkg files (MacPkg only supports making a
  # single component). This is done with `pkgbuild`. Next the component(s)
  # are combined into a single "product" package, using `productbuild`. It is
  # this container package that can have custom branding (background image)
  # and a license. It can also allow for user customization of which
  # component packages to install, but MacPkg does not expose this feature.
  class Packager::MacPkg < Packager::Base
    validate do
      assert_presence!(resource('background.png'))
      assert_presence!(resource('license.html'))
      assert_presence!(resource('welcome.html'))
    end

    setup do
      purge_directory(staging_dir)
      purge_directory(Config.package_dir)
      purge_directory(staging_resources_path)
      copy_directory(resources_path, staging_resources_path)

      # Render resource templates if needed
      ['license.html.erb', 'welcome.html.erb'].each do |res|
        res_path = resource(res)
        render_template(res_path) if File.exist?(res_path)
      end
    end

    build do
      build_component_pkg
      generate_distribution
      build_product_pkg

      if Config.build_dmg
        Packager::MacDmg.new(self).run!
      end
    end

    clean do
      # There is nothing to cleanup
    end

    # @see Base#package_name
    def package_name
      "#{project.name}-#{project.build_version}-#{project.iteration}.pkg"
    end

    # The full path where the product package was/will be written.
    #
    # @return [String] Path to the packge file.
    def final_pkg
      File.expand_path("#{Config.package_dir}/#{package_name}")
    end

    #
    # Construct the intermediate build product. It can be installed with the
    # Installer.app, but doesn't contain the data needed to customize the
    # installer UI.
    #
    def build_component_pkg
      execute <<-EOH.gsub(/^ {8}/, '')
        pkgbuild \\
          --identifier "#{identifier}" \\
          --version "#{project.build_version}" \\
          --scripts "#{project.package_scripts_path}" \\
          --root "#{project.install_path}" \\
          --install-location "#{project.install_path}" \\
          "#{component_pkg}"
      EOH
    end

    #
    # Write the Distribution file to the staging area. This method generates the
    # content of the Distribution file, which is used by +productbuild+ to
    # select the component packages to include in the product package.
    #
    # It also includes information used to customize the UI of the Mac OS X
    # installer.
    #
    def generate_distribution
      File.open(distribution_file, 'w', 0600) do |file|
        file.puts <<-EOH.gsub(/^ {10}/, '')
          <?xml version="1.0" standalone="no"?>
          <installer-gui-script minSpecVersion="1">
              <title>#{project.friendly_name}</title>
              <background file="background.png" alignment="bottomleft" mime-type="image/png"/>
              <welcome file="welcome.html" mime-type="text/html"/>
              <license file="license.html" mime-type="text/html"/>

              <!-- Generated by productbuild - - synthesize -->
              <pkg-ref id="#{identifier}"/>
              <options customize="never" require-scripts="false"/>
              <choices-outline>
                  <line choice="default">
                      <line choice="#{identifier}"/>
                  </line>
              </choices-outline>
              <choice id="default"/>
              <choice id="#{identifier}" visible="false">
                  <pkg-ref id="#{identifier}"/>
              </choice>
              <pkg-ref id="#{identifier}" version="#{project.build_version}" onConclusion="none">#{component_pkg}</pkg-ref>
          </installer-gui-script>
        EOH
      end
    end

    #
    # Construct the product package. The generated package is the final build
    # product that is shipped to end users.
    #
    def build_product_pkg
      command = <<-EOH.gsub(/^ {8}/, '')
        productbuild \\
          --distribution "#{distribution_file}" \\
          --resources "#{staging_resources_path}" \\
      EOH

      command << %Q(  --sign "#{Config.signing_identity}" \\\n) if Config.sign_pkg
      command << %Q(  "#{final_pkg}")
      command << %Q(\n)

      execute(command)
    end

    # The identifier for this mac package (the com.whatever.thing.whatever).
    # This is a configurable project value, but a default value is calculated if
    # one is not given.
    #
    # @return [String]
    def identifier
      @identifier ||= project.mac_pkg_identifier ||
        "test.#{sanitize(project.maintainer)}.pkg.#{sanitize(project.name)}"
    end

    # Filesystem path where the Distribution XML file is written.
    #
    # @return [String]
    def distribution_file
      File.expand_path("#{staging_dir}/Distribution")
    end

    # The name of the (only) component package.
    #
    # @return [String] the filename of the component .pkg file to create.
    def component_pkg
      "#{project.name}-core.pkg"
    end

    # Sanitize the given string for the package identifier.
    #
    # @param [String]
    # @return [String]
    def sanitize(string)
      string.gsub(/[^[:alnum:]]/, '').downcase
    end
  end
end
