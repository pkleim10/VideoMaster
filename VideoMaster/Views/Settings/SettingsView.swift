import GRDB
import SwiftUI

struct SettingsView: View {
    let dbPool: GRDB.DatabasePool

    var body: some View {
        TabView {
            DataSourcesSettingsView(dbPool: dbPool)
                .tabItem {
                    Label("Data Sources", systemImage: "folder")
                }
        }
        .frame(minWidth: 500, minHeight: 350)
    }
}
