import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import {
  Pressable,
  SafeAreaView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

export default function HomeScreen() {
  return (
    <SafeAreaView style={styles.container}>
      <StatusBar style="dark" />

      <View style={styles.content}>
        <Text style={styles.brand}>Haulvia</Text>

        <Text style={styles.heading}>
          Move small loads with less friction.
        </Text>

        <Text style={styles.description}>
          Post a delivery, receive driver offers, track the trip, and confirm
          secure handoff.
        </Text>

        <Pressable
          onPress={() => router.push('/post-load')}
          style={({ pressed }) => [
            styles.card,
            pressed && styles.cardPressed,
          ]}
        >
          <Text style={styles.cardLabel}>Customer app</Text>

          <Text style={styles.cardTitle}>Post your first load</Text>

          <Text style={styles.cardText}>
            Enter the pickup, delivery, load details, timing, and pricing
            information.
          </Text>

          <Text style={styles.cardAction}>Start posting {'\u2192'}</Text>
        </Pressable>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F7F9FC',
  },
  content: {
    flex: 1,
    paddingHorizontal: 24,
    paddingTop: 48,
  },
  brand: {
    color: '#1D4ED8',
    fontSize: 22,
    fontWeight: '800',
    marginBottom: 28,
  },
  heading: {
    color: '#111827',
    fontSize: 36,
    fontWeight: '800',
    lineHeight: 43,
    maxWidth: 340,
  },
  description: {
    color: '#4B5563',
    fontSize: 17,
    lineHeight: 26,
    marginTop: 18,
    maxWidth: 340,
  },
  card: {
    backgroundColor: '#FFFFFF',
    borderRadius: 22,
    padding: 22,
    marginTop: 40,
    shadowColor: '#000000',
    shadowOffset: {
      width: 0,
      height: 8,
    },
    shadowOpacity: 0.08,
    shadowRadius: 20,
    elevation: 4,
  },
  cardPressed: {
    opacity: 0.78,
    transform: [{ scale: 0.99 }],
  },
  cardLabel: {
    color: '#1D4ED8',
    fontSize: 13,
    fontWeight: '700',
    letterSpacing: 0.8,
    textTransform: 'uppercase',
  },
  cardTitle: {
    color: '#111827',
    fontSize: 22,
    fontWeight: '800',
    marginTop: 10,
  },
  cardText: {
    color: '#6B7280',
    fontSize: 15,
    lineHeight: 23,
    marginTop: 10,
  },
  cardAction: {
    color: '#1D4ED8',
    fontSize: 16,
    fontWeight: '800',
    marginTop: 20,
  },
});