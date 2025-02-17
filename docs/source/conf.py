# Configuration file for the Sphinx documentation builder.
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# -- Project information -----------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#project-information

project = 'wsprdaemon'
copyright = '2025, Rob Robinett'
author = 'Rob Robinett'
release = '3.3.1'

# -- General configuration ---------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#general-configuration

extensions = [
    'myst_parser',
    'sphinx.ext.autodoc',
    'sphinx.ext.viewcode',
    'sphinx.ext.napoleon',
    'sphinx.ext.mathjax'
]

myst_enable_extentions = [
	"amsmath",  # Enables AMS-style math environments like align
    "html_image"
]

html_theme = 'sphinx_rtd_theme'

templates_path = ['_templates']
exclude_patterns = []

html_static_path = ['_static']
