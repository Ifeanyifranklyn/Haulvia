import { router } from 'expo-router';
import { useState } from 'react';
import {
    KeyboardAvoidingView,
    Platform,
    Pressable,
    SafeAreaView,
    ScrollView,
    StyleSheet,
    Text,
    TextInput,
    View,
} from 'react-native';

export default function PostLoadScreen() {
  const [pickupLocation, setPickupLocation] = useState('');
  const [deliveryLocation, setDeliveryLocation] = useState('');
  const [showErrors, setShowErrors] = useState(false);

  const pickupIsValid = pickupLocation.trim().length > 0;
  const deliveryIsValid = deliveryLocation.trim().length > 0;
  const formIsValid = pickupIsValid && deliveryIsValid;

  const handleContinue = () => {
  setShowErrors(true);

  if (!formIsValid) {
    return;
  }

  router.push({
    pathname: '/post-load/load-details',
    params: {
      pickupLocation: pickupLocation.trim(),
      deliveryLocation: deliveryLocation.trim(),
    },
  });
};

  return (
    <SafeAreaView style={styles.container}>
      <KeyboardAvoidingView
        style={styles.keyboardView}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      >
        <ScrollView
          contentContainerStyle={styles.scrollContent}
          keyboardShouldPersistTaps="handled"
          showsVerticalScrollIndicator={false}
        >
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Go back"
            hitSlop={12}
            onPress={() => router.back()}
            style={({ pressed }) => [
              styles.backButton,
              pressed && styles.backButtonPressed,
            ]}
          >
            <Text style={styles.backButtonText}>
              {'\u2190'} Back
            </Text>
          </Pressable>

          <View style={styles.progressHeader}>
            <Text style={styles.step}>STEP 1 OF 5</Text>
            <Text style={styles.progressPercent}>20%</Text>
          </View>

          <View style={styles.progressTrack}>
            <View style={styles.progressFill} />
          </View>

          <Text style={styles.heading}>Where is the load going?</Text>

          <Text style={styles.description}>
            Enter the pickup and delivery addresses for this load.
          </Text>

          <View style={styles.form}>
            <View style={styles.fieldGroup}>
              <Text style={styles.label}>Pickup location</Text>

              <TextInput
                accessibilityLabel="Pickup location"
                autoCapitalize="words"
                autoCorrect={false}
                onChangeText={(value) => {
                  setPickupLocation(value);

                  if (showErrors && value.trim().length > 0) {
                    setShowErrors(false);
                  }
                }}
                placeholder="Enter pickup address"
                placeholderTextColor="#9CA3AF"
                returnKeyType="next"
                style={[
                  styles.input,
                  showErrors && !pickupIsValid && styles.inputError,
                ]}
                value={pickupLocation}
              />

              {showErrors && !pickupIsValid ? (
                <Text style={styles.errorText}>
                  Enter a pickup location.
                </Text>
              ) : (
                <Text style={styles.helperText}>
                  Where should the driver collect the load?
                </Text>
              )}
            </View>

            <View style={styles.fieldGroup}>
              <Text style={styles.label}>Delivery location</Text>

              <TextInput
                accessibilityLabel="Delivery location"
                autoCapitalize="words"
                autoCorrect={false}
                onChangeText={(value) => {
                  setDeliveryLocation(value);

                  if (showErrors && value.trim().length > 0) {
                    setShowErrors(false);
                  }
                }}
                onSubmitEditing={handleContinue}
                placeholder="Enter delivery address"
                placeholderTextColor="#9CA3AF"
                returnKeyType="done"
                style={[
                  styles.input,
                  showErrors && !deliveryIsValid && styles.inputError,
                ]}
                value={deliveryLocation}
              />

              {showErrors && !deliveryIsValid ? (
                <Text style={styles.errorText}>
                  Enter a delivery location.
                </Text>
              ) : (
                <Text style={styles.helperText}>
                  Where should the driver deliver the load?
                </Text>
              )}
            </View>
          </View>

          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Continue to load details"
            onPress={handleContinue}
            style={({ pressed }) => [
              styles.continueButton,
              pressed && styles.continueButtonPressed,
            ]}
          >
            <Text style={styles.continueButtonText}>
              Continue {'\u2192'}
            </Text>
          </Pressable>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F7F9FC',
  },
  keyboardView: {
    flex: 1,
  },
  scrollContent: {
    flexGrow: 1,
    paddingHorizontal: 24,
    paddingTop: 24,
    paddingBottom: 36,
  },
  backButton: {
    alignSelf: 'flex-start',
    paddingVertical: 12,
  },
  backButtonPressed: {
    opacity: 0.65,
  },
  backButtonText: {
    color: '#1D4ED8',
    fontSize: 16,
    fontWeight: '700',
  },
  progressHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginTop: 28,
  },
  step: {
    color: '#1D4ED8',
    fontSize: 13,
    fontWeight: '800',
    letterSpacing: 1,
  },
  progressPercent: {
    color: '#6B7280',
    fontSize: 13,
    fontWeight: '700',
  },
  progressTrack: {
    backgroundColor: '#DDE5F3',
    borderRadius: 999,
    height: 6,
    marginTop: 12,
    overflow: 'hidden',
  },
  progressFill: {
    backgroundColor: '#1D4ED8',
    borderRadius: 999,
    height: '100%',
    width: '20%',
  },
  heading: {
    color: '#111827',
    fontSize: 34,
    fontWeight: '800',
    lineHeight: 41,
    marginTop: 30,
  },
  description: {
    color: '#6B7280',
    fontSize: 17,
    lineHeight: 26,
    marginTop: 12,
  },
  form: {
    marginTop: 32,
  },
  fieldGroup: {
    marginBottom: 24,
  },
  label: {
    color: '#111827',
    fontSize: 15,
    fontWeight: '700',
    marginBottom: 9,
  },
  input: {
    backgroundColor: '#FFFFFF',
    borderColor: '#DCE1E9',
    borderRadius: 16,
    borderWidth: 1,
    color: '#111827',
    fontSize: 16,
    minHeight: 60,
    paddingHorizontal: 18,
  },
  inputError: {
    borderColor: '#DC2626',
  },
  helperText: {
    color: '#6B7280',
    fontSize: 13,
    lineHeight: 19,
    marginTop: 8,
  },
  errorText: {
    color: '#DC2626',
    fontSize: 13,
    fontWeight: '600',
    lineHeight: 19,
    marginTop: 8,
  },
  continueButton: {
    alignItems: 'center',
    backgroundColor: '#1D4ED8',
    borderRadius: 16,
    justifyContent: 'center',
    minHeight: 58,
    marginTop: 6,
    paddingHorizontal: 20,
  },
  continueButtonPressed: {
    opacity: 0.82,
    transform: [{ scale: 0.99 }],
  },
  continueButtonText: {
    color: '#FFFFFF',
    fontSize: 17,
    fontWeight: '800',
  },
  addressNotice: {
    color: '#6B7280',
    fontSize: 12,
    lineHeight: 18,
    marginTop: 14,
    textAlign: 'center',
  },
});