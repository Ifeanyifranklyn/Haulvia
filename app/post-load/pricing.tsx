import { Stack } from "expo-router";
import {
    SafeAreaView,
    ScrollView,
    StatusBar,
    StyleSheet,
    Text
} from "react-native";

export default function PricingScreen() {
  return (
    <>
      <Stack.Screen
        options={{
          title: "Pricing",
          headerBackTitle: "Schedule",
        }}
      />

      <SafeAreaView style={styles.container}>
        <StatusBar barStyle="dark-content" />

        <ScrollView
          contentContainerStyle={styles.content}
          showsVerticalScrollIndicator={false}
        >
          <Text style={styles.step}>STEP 4 OF 5</Text>

          <Text style={styles.title}>
            Choose your pricing option
          </Text>

          <Text style={styles.subtitle}>
            Select whether you want the fastest guaranteed service or a
            negotiable delivery.
          </Text>
        </ScrollView>
      </SafeAreaView>
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#F7F9FC",
  },

  content: {
    padding: 24,
  },

  step: {
    color: "#1D4ED8",
    fontWeight: "700",
    letterSpacing: 1,
    marginBottom: 10,
  },

  title: {
    fontSize: 32,
    fontWeight: "800",
    color: "#111827",
    marginBottom: 12,
  },

  subtitle: {
    fontSize: 18,
    color: "#6B7280",
    lineHeight: 28,
  },
});