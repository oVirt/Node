"""
Configure KDump
"""
import logging

import ovirt.node.plugins
import ovirt.node.valid
import ovirt.node.plugins
import ovirt.node.utils

LOGGER = logging.getLogger(__name__)


class Plugin(ovirt.node.plugins.NodePlugin):
    _model = None
    _widgets = None

    _types = [
                 ("local", "Local"),
                 ("ssh", "SSH"),
                 ("nfs", "NFS")
             ]

    def name(self):
        return "Kdump"

    def rank(self):
        return 70

    def model(self):
        """Returns the model of this plugin
        This is expected to parse files and all stuff to build up the model.
        """
        if not self._model:
            self._model = {
                # The target address
                "kdump.type": "ssh",
                "kdump.ssh_location": "",
                "kdump.nfs_location": "",
            }
        return self._model

    def validators(self):
        """Validators validate the input on change and give UI feedback
        """
        options = dict(self._types).keys()
        return {
                "kdump.type": ovirt.node.valid.Options(options),
                "kdump.ssh_location": ovirt.node.valid.NoSpaces(),
                "kdump.nfs_location": ovirt.node.valid.NoSpaces(),
            }

    def ui_content(self):
        """Describes the UI this plugin requires
        This is an ordered list of (path, widget) tuples.
        """
        widgets = [
            ("kdump.header", ovirt.node.plugins.Header("Configure Kdump")),
            ("kdump.type", ovirt.node.plugins.Options("Type", self._types)),
            ("kdump.ssh_location", ovirt.node.plugins.Entry("SSH Location")),
            ("kdump.nfs_location", ovirt.node.plugins.Entry("NFS Location")),
        ]
        # Save it "locally" as a dict, for better accessability
        self._widgets = dict(widgets)
        return widgets

    def on_change(self, changes):
        """Applies the changes to the plugins model, will do all required logic
        """
        LOGGER.debug("New (valid) address: %s" % changes)
        if "kdump.type" in changes:
            net_types = ["kdump.ssh_location", "kdump.nfs_location"]

            for w in net_types:
                self._widgets[w].enabled(False)

            w = "kdump.%s_location" % changes["kdump.type"]
            if w in net_types:
                self._widgets[w].enabled(True),

            self._model.update(changes)

    def on_merge(self, effective_changes):
        """Applies the changes to the plugins model, will do all required logic
        Normally on_merge is called by pushing the SaveButton instance, in this
        case it is called by on_change
        """

        if effective_changes:
            LOGGER.debug("Generating conf according to model and changes")
        else:
            LOGGER.debug("Generating no new conf as there are no changes")
