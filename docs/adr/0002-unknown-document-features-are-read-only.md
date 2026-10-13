# Unknown document features are read-only

In the first release, a document becomes read-only when a client encounters semantic features it cannot safely understand. The client preserves the document unchanged rather than risking silent content loss through partial editing; mixed-version editing can be enabled only after preservation is demonstrated.
