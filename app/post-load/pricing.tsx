import { router, Stack, useLocalSearchParams } from 'expo-router';
import { useMemo, useState } from 'react';
import {
  KeyboardAvoidingView,
  Platform,
  Pressable,
  SafeAreaView,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import {
  calculatePrice,
  ScheduleDetailsPayload,
  ServiceType,
} from '../../lib/pricing/calculate-price';

function formatCurrency(value: number) {
  return new Intl.NumberFormat('en-CA', {
    style: 'currency',
    currency: 'CAD',
    minimumFractionDigits: 2,
  }).format(value);
}

function normalizeBudgetInput(value: string) {
  const cleanedValue = value.replace(/[^0-9.]/g, '');
  const parts = cleanedValue.split('.');

  if (parts.length <= 1) {
    return cleanedValue;
  }

  return `${parts[0]}.${parts.slice(1).join('').slice(0, 2)}`;
}

export default function PricingScreen() {
  const params = useLocalSearchParams<{
    scheduleDetails?: string;
  }>();

  const scheduleDetails =
    useMemo<ScheduleDetailsPayload | null>(() => {
      const rawValue = Array.isArray(params.scheduleDetails)
        ? params.scheduleDetails[0]
        : params.scheduleDetails;

      if (!rawValue) {
        return null;
      }

      try {
        return JSON.parse(
          rawValue,
        ) as ScheduleDetailsPayload;
      } catch {
        return null;
      }
    }, [params.scheduleDetails]);

  const pricing = useMemo(() => {
    if (!scheduleDetails) {
      return null;
    }

    return calculatePrice(scheduleDetails);
  }, [scheduleDetails]);

  const [selectedService, setSelectedService] =
    useState<ServiceType | null>(null);

  const [flexBudget, setFlexBudget] = useState('');
  const [showErrors, setShowErrors] = useState(false);

  const parsedFlexBudget = Number(flexBudget);

  const flexBudgetIsValid =
    selectedService !== 'flex' ||
    (Number.isFinite(parsedFlexBudget) &&
      parsedFlexBudget > 0);

  const formIsValid =
    scheduleDetails !== null &&
    pricing !== null &&
    selectedService !== null &&
    flexBudgetIsValid;

  const selectService = (service: ServiceType) => {
    setSelectedService(service);
    setShowErrors(false);

    if (
      service === 'flex' &&
      !flexBudget &&
      pricing
    ) {
      setFlexBudget(
        pricing.flex.recommendedBudget.toFixed(2),
      );
    }
  };

  const handleContinue = () => {
    setShowErrors(true);

    if (
      !formIsValid ||
      !scheduleDetails ||
      !pricing ||
      !selectedService
    ) {
      return;
    }

    const selectedPrice =
      selectedService === 'expedited'
        ? pricing.expedited.price
        : parsedFlexBudget;

    const pricingSelection = {
      ...scheduleDetails,

      pricing: {
        serviceType: selectedService,
        currency: pricing.currency,

        selectedPrice,
        customerBudget:
          selectedService === 'flex'
            ? parsedFlexBudget
            : null,

        suggestedFlexRange: {
          minimum: pricing.flex.suggestedMinimum,
          maximum: pricing.flex.suggestedMaximum,
        },

        expeditedPrice: pricing.expedited.price,

        engineSnapshot: {
          ruleVersion: pricing.ruleVersion,
          calculatedAt: pricing.calculatedAt,
          assumptions: pricing.assumptions,

          expeditedComponents:
            pricing.expedited.components,

          flexComponents: pricing.flex.components,
        },
      },
    };

    router.push({
      pathname: '/post-load/review',
      params: {
        pricingSelection: JSON.stringify(
          pricingSelection,
        ),
      },
    });
  };

  return (
    <>
      <Stack.Screen
        options={{
          title: 'Pricing',
          headerBackTitle: 'Schedule',
        }}
      />

      <SafeAreaView style={styles.container}>
        <StatusBar barStyle="dark-content" />

        <KeyboardAvoidingView
          behavior={
            Platform.OS === 'ios' ? 'padding' : undefined
          }
          style={styles.keyboardContainer}
        >
          <ScrollView
            contentContainerStyle={styles.content}
            keyboardShouldPersistTaps="handled"
            showsVerticalScrollIndicator={false}
          >
            <View style={styles.progressHeader}>
              <Text style={styles.step}>STEP 4 OF 5</Text>
              <Text style={styles.progressPercent}>80%</Text>
            </View>

            <View style={styles.progressTrack}>
              <View style={styles.progressFill} />
            </View>

            <Text style={styles.title}>
              Choose your service
            </Text>

            <Text style={styles.subtitle}>
              Select the fastest available service or choose
              a flexible budget.
            </Text>

            {!scheduleDetails || !pricing ? (
              <View style={styles.dataErrorCard}>
                <Text style={styles.dataErrorTitle}>
                  Pricing information is unavailable
                </Text>

                <Text style={styles.dataErrorText}>
                  Go back and complete the previous steps
                  again.
                </Text>
              </View>
            ) : (
              <>
                <View style={styles.serviceList}>
                  <Pressable
                    accessibilityRole="radio"
                    accessibilityState={{
                      selected:
                        selectedService === 'expedited',
                    }}
                    onPress={() =>
                      selectService('expedited')
                    }
                    style={({ pressed }) => [
                      styles.serviceCard,
                      selectedService === 'expedited' &&
                        styles.serviceCardSelected,
                      pressed && styles.pressed,
                    ]}
                  >
                    <View style={styles.cardTopRow}>
                      <View style={styles.serviceIdentity}>
                        <View style={styles.serviceIcon}>
                          <Text style={styles.serviceIconText}>
                            🚀
                          </Text>
                        </View>

                        <View style={styles.serviceTitleGroup}>
                          <Text
                            style={[
                              styles.serviceTitle,
                              selectedService ===
                                'expedited' &&
                                styles.selectedText,
                            ]}
                          >
                            Expedited
                          </Text>

                          <Text style={styles.serviceDescription}>
                            Priority pickup and delivery.
                          </Text>
                        </View>
                      </View>

                      <View
                        style={[
                          styles.badge,
                          styles.fastestBadge,
                        ]}
                      >
                        <Text style={styles.fastestBadgeText}>
                          FASTEST
                        </Text>
                      </View>
                    </View>

                    <View style={styles.featureList}>
                      <Text style={styles.featureText}>
                        ✓ Fixed price
                      </Text>
                      <Text style={styles.featureText}>
                        ✓ No negotiation
                      </Text>
                      <Text style={styles.featureText}>
                        ✓ Priority driver matching
                      </Text>
                      <Text style={styles.featureText}>
                        ✓ Direct priority delivery
                      </Text>
                    </View>

                    <View style={styles.commitmentGrid}>
                      <View style={styles.commitmentItem}>
                        <Text style={styles.commitmentLabel}>
                          Pickup
                        </Text>
                        <Text style={styles.commitmentValue}>
                          Priority target
                        </Text>
                      </View>

                      <View style={styles.commitmentDivider} />

                      <View style={styles.commitmentItem}>
                        <Text style={styles.commitmentLabel}>
                          Delivery
                        </Text>
                        <Text style={styles.commitmentValue}>
                          Direct priority
                        </Text>
                      </View>
                    </View>

                    <View style={styles.priceRow}>
                      <View>
                        <Text style={styles.priceLabel}>
                          Estimated fixed price
                        </Text>
                        <Text style={styles.priceDetail}>
                          Before applicable taxes
                        </Text>
                      </View>

                      <Text style={styles.priceValue}>
                        {formatCurrency(
                          pricing.expedited.price,
                        )}
                      </Text>
                    </View>

                    <View
                      style={[
                        styles.radioOuter,
                        selectedService === 'expedited' &&
                          styles.radioOuterSelected,
                      ]}
                    >
                      {selectedService === 'expedited' ? (
                        <View style={styles.radioInner} />
                      ) : null}
                    </View>
                  </Pressable>

                  <Pressable
                    accessibilityRole="radio"
                    accessibilityState={{
                      selected: selectedService === 'flex',
                    }}
                    onPress={() => selectService('flex')}
                    style={({ pressed }) => [
                      styles.serviceCard,
                      selectedService === 'flex' &&
                        styles.serviceCardSelected,
                      pressed && styles.pressed,
                    ]}
                  >
                    <View style={styles.cardTopRow}>
                      <View style={styles.serviceIdentity}>
                        <View style={styles.serviceIcon}>
                          <Text style={styles.serviceIconText}>
                            🤝
                          </Text>
                        </View>

                        <View style={styles.serviceTitleGroup}>
                          <Text
                            style={[
                              styles.serviceTitle,
                              selectedService === 'flex' &&
                                styles.selectedText,
                            ]}
                          >
                            Flex
                          </Text>

                          <Text style={styles.serviceDescription}>
                            Set a budget and receive driver
                            offers.
                          </Text>
                        </View>
                      </View>

                      <View
                        style={[
                          styles.badge,
                          styles.valueBadge,
                        ]}
                      >
                        <Text style={styles.valueBadgeText}>
                          BEST VALUE
                        </Text>
                      </View>
                    </View>

                    <View style={styles.featureList}>
                      <Text style={styles.featureText}>
                        ✓ Choose your budget
                      </Text>
                      <Text style={styles.featureText}>
                        ✓ Drivers can counteroffer
                      </Text>
                      <Text style={styles.featureText}>
                        ✓ Lower-cost opportunity
                      </Text>
                      <Text style={styles.featureText}>
                        ✓ Best for non-urgent loads
                      </Text>
                    </View>

                    <View style={styles.flexRangeBox}>
                      <Text style={styles.flexRangeLabel}>
                        Suggested budget
                      </Text>

                      <Text style={styles.flexRangeValue}>
                        {formatCurrency(
                          pricing.flex.suggestedMinimum,
                        )}{' '}
                        –{' '}
                        {formatCurrency(
                          pricing.flex.suggestedMaximum,
                        )}
                      </Text>
                    </View>

                    {selectedService === 'flex' ? (
                      <View style={styles.budgetSection}>
                        <Text style={styles.budgetLabel}>
                          Your budget
                        </Text>

                        <View
                          style={[
                            styles.budgetInputContainer,
                            showErrors &&
                              !flexBudgetIsValid &&
                              styles.inputError,
                          ]}
                        >
                          <Text style={styles.currencyPrefix}>
                            $
                          </Text>

                          <TextInput
                            accessibilityLabel="Your Flex budget"
                            keyboardType="decimal-pad"
                            onChangeText={(value) =>
                              setFlexBudget(
                                normalizeBudgetInput(value),
                              )
                            }
                            placeholder="0.00"
                            placeholderTextColor="#9CA3AF"
                            style={styles.budgetInput}
                            value={flexBudget}
                          />

                          <Text style={styles.currencyCode}>
                            CAD
                          </Text>
                        </View>

                        <Text style={styles.budgetHelper}>
                          Drivers may accept this budget or
                          submit a counteroffer.
                        </Text>

                        {showErrors &&
                        !flexBudgetIsValid ? (
                          <Text style={styles.errorText}>
                            Enter a valid Flex budget.
                          </Text>
                        ) : null}
                      </View>
                    ) : null}

                    <View
                      style={[
                        styles.radioOuter,
                        selectedService === 'flex' &&
                          styles.radioOuterSelected,
                      ]}
                    >
                      {selectedService === 'flex' ? (
                        <View style={styles.radioInner} />
                      ) : null}
                    </View>
                  </Pressable>
                </View>

                {showErrors && !selectedService ? (
                  <Text style={styles.serviceError}>
                    Select Expedited or Flex to continue.
                  </Text>
                ) : null}

                {selectedService ? (
                  <View style={styles.summaryCard}>
                    <View style={styles.summaryHeader}>
                      <Text style={styles.summaryTitle}>
                        Price summary
                      </Text>

                      <Text style={styles.summaryService}>
                        {selectedService === 'expedited'
                          ? 'Expedited'
                          : 'Flex'}
                      </Text>
                    </View>

                    <View style={styles.summaryDivider} />

                    <View style={styles.summaryPriceRow}>
                      <Text style={styles.summaryPriceLabel}>
                        {selectedService === 'expedited'
                          ? 'Estimated cost'
                          : 'Your budget'}
                      </Text>

                      <Text style={styles.summaryPriceValue}>
                        {selectedService === 'expedited'
                          ? formatCurrency(
                              pricing.expedited.price,
                            )
                          : flexBudgetIsValid
                            ? formatCurrency(
                                parsedFlexBudget,
                              )
                            : '—'}
                      </Text>
                    </View>

                    <Text style={styles.summaryNote}>
                      {selectedService === 'expedited'
                        ? 'This is a fixed estimated price for priority service.'
                        : 'Drivers can accept your budget or submit a counteroffer.'}
                    </Text>
                  </View>
                ) : null}

                <View style={styles.trustCard}>
                  <Text style={styles.trustTitle}>
                    Good to know
                  </Text>

                  <Text style={styles.trustItem}>
                    ✓ No payment is taken when you post.
                  </Text>
                  <Text style={styles.trustItem}>
                    ✓ Deliveries include live tracking.
                  </Text>
                  <Text style={styles.trustItem}>
                    ✓ Secure handoff confirmation is included.
                  </Text>
                  <Text style={styles.trustItem}>
                    ✓ Proof of delivery is stored in your
                    account.
                  </Text>
                </View>

                <Text style={styles.developmentNote}>
                  Pricing Engine {pricing.ruleVersion}
                </Text>
              </>
            )}

            <Pressable
              accessibilityLabel="Continue to review"
              accessibilityRole="button"
              onPress={handleContinue}
              style={({ pressed }) => [
                styles.continueButton,
                (!scheduleDetails || !pricing) &&
                  styles.continueButtonDisabled,
                pressed &&
                  scheduleDetails &&
                  pricing &&
                  styles.continueButtonPressed,
              ]}
            >
              <Text style={styles.continueButtonText}>
                Continue to review →
              </Text>
            </Pressable>
          </ScrollView>
        </KeyboardAvoidingView>
      </SafeAreaView>
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F7F9FC',
  },
  keyboardContainer: {
    flex: 1,
  },
  content: {
    flexGrow: 1,
    paddingHorizontal: 24,
    paddingTop: 24,
    paddingBottom: 40,
  },
  progressHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
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
    width: '80%',
  },
  title: {
    color: '#111827',
    fontSize: 34,
    fontWeight: '800',
    lineHeight: 41,
    marginTop: 30,
  },
  subtitle: {
    color: '#6B7280',
    fontSize: 17,
    lineHeight: 26,
    marginTop: 12,
  },
  serviceList: {
    gap: 16,
    marginTop: 28,
  },
  serviceCard: {
    backgroundColor: '#FFFFFF',
    borderColor: '#DCE1E9',
    borderRadius: 22,
    borderWidth: 1,
    padding: 18,
    position: 'relative',
  },
  serviceCardSelected: {
    backgroundColor: '#F1F5FF',
    borderColor: '#1D4ED8',
    borderWidth: 2,
  },
  pressed: {
    opacity: 0.82,
  },
  cardTopRow: {
    alignItems: 'flex-start',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  serviceIdentity: {
    flex: 1,
    flexDirection: 'row',
    paddingRight: 10,
  },
  serviceIcon: {
    alignItems: 'center',
    backgroundColor: '#EEF3FF',
    borderRadius: 14,
    height: 48,
    justifyContent: 'center',
    marginRight: 12,
    width: 48,
  },
  serviceIconText: {
    fontSize: 23,
  },
  serviceTitleGroup: {
    flex: 1,
  },
  serviceTitle: {
    color: '#111827',
    fontSize: 21,
    fontWeight: '800',
  },
  selectedText: {
    color: '#1D4ED8',
  },
  serviceDescription: {
    color: '#6B7280',
    fontSize: 13,
    lineHeight: 19,
    marginTop: 4,
  },
  badge: {
    borderRadius: 999,
    paddingHorizontal: 9,
    paddingVertical: 6,
  },
  fastestBadge: {
    backgroundColor: '#DBEAFE',
  },
  fastestBadgeText: {
    color: '#1D4ED8',
    fontSize: 10,
    fontWeight: '900',
    letterSpacing: 0.6,
  },
  valueBadge: {
    backgroundColor: '#DCFCE7',
  },
  valueBadgeText: {
    color: '#15803D',
    fontSize: 10,
    fontWeight: '900',
    letterSpacing: 0.5,
  },
  featureList: {
    gap: 7,
    marginTop: 20,
  },
  featureText: {
    color: '#4B5563',
    fontSize: 14,
    fontWeight: '600',
  },
  commitmentGrid: {
    alignItems: 'stretch',
    backgroundColor: '#F8FAFC',
    borderRadius: 14,
    flexDirection: 'row',
    marginTop: 18,
    paddingVertical: 14,
  },
  commitmentItem: {
    flex: 1,
    paddingHorizontal: 12,
  },
  commitmentDivider: {
    backgroundColor: '#E2E8F0',
    width: 1,
  },
  commitmentLabel: {
    color: '#6B7280',
    fontSize: 11,
    fontWeight: '700',
    textTransform: 'uppercase',
  },
  commitmentValue: {
    color: '#111827',
    fontSize: 13,
    fontWeight: '800',
    marginTop: 4,
  },
  priceRow: {
    alignItems: 'flex-end',
    borderTopColor: '#E5E7EB',
    borderTopWidth: 1,
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginTop: 18,
    paddingTop: 16,
  },
  priceLabel: {
    color: '#111827',
    fontSize: 13,
    fontWeight: '800',
  },
  priceDetail: {
    color: '#6B7280',
    fontSize: 11,
    marginTop: 3,
  },
  priceValue: {
    color: '#1D4ED8',
    fontSize: 24,
    fontWeight: '900',
  },
  flexRangeBox: {
    backgroundColor: '#F0FDF4',
    borderRadius: 14,
    marginTop: 18,
    padding: 15,
  },
  flexRangeLabel: {
    color: '#15803D',
    fontSize: 11,
    fontWeight: '800',
    textTransform: 'uppercase',
  },
  flexRangeValue: {
    color: '#14532D',
    fontSize: 21,
    fontWeight: '900',
    marginTop: 5,
  },
  budgetSection: {
    marginTop: 18,
  },
  budgetLabel: {
    color: '#111827',
    fontSize: 14,
    fontWeight: '800',
    marginBottom: 8,
  },
  budgetInputContainer: {
    alignItems: 'center',
    backgroundColor: '#FFFFFF',
    borderColor: '#CBD5E1',
    borderRadius: 14,
    borderWidth: 1,
    flexDirection: 'row',
    minHeight: 58,
    paddingHorizontal: 15,
  },
  currencyPrefix: {
    color: '#111827',
    fontSize: 19,
    fontWeight: '800',
  },
  budgetInput: {
    color: '#111827',
    flex: 1,
    fontSize: 19,
    fontWeight: '800',
    paddingHorizontal: 8,
    paddingVertical: 0,
  },
  currencyCode: {
    color: '#6B7280',
    fontSize: 12,
    fontWeight: '800',
  },
  budgetHelper: {
    color: '#6B7280',
    fontSize: 12,
    lineHeight: 18,
    marginTop: 8,
  },
  inputError: {
    borderColor: '#DC2626',
  },
  errorText: {
    color: '#DC2626',
    fontSize: 12,
    fontWeight: '700',
    marginTop: 8,
  },
  radioOuter: {
    alignItems: 'center',
    borderColor: '#C7CED9',
    borderRadius: 999,
    borderWidth: 2,
    height: 22,
    justifyContent: 'center',
    position: 'absolute',
    right: 18,
    top: 75,
    width: 22,
  },
  radioOuterSelected: {
    borderColor: '#1D4ED8',
  },
  radioInner: {
    backgroundColor: '#1D4ED8',
    borderRadius: 999,
    height: 10,
    width: 10,
  },
  serviceError: {
    color: '#DC2626',
    fontSize: 13,
    fontWeight: '700',
    marginTop: 12,
  },
  summaryCard: {
    backgroundColor: '#111827',
    borderRadius: 20,
    marginTop: 26,
    padding: 20,
  },
  summaryHeader: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  summaryTitle: {
    color: '#FFFFFF',
    fontSize: 17,
    fontWeight: '800',
  },
  summaryService: {
    color: '#BFDBFE',
    fontSize: 13,
    fontWeight: '800',
  },
  summaryDivider: {
    backgroundColor: '#374151',
    height: 1,
    marginVertical: 16,
  },
  summaryPriceRow: {
    alignItems: 'flex-end',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  summaryPriceLabel: {
    color: '#D1D5DB',
    fontSize: 13,
    fontWeight: '700',
  },
  summaryPriceValue: {
    color: '#FFFFFF',
    fontSize: 27,
    fontWeight: '900',
  },
  summaryNote: {
    color: '#9CA3AF',
    fontSize: 12,
    lineHeight: 18,
    marginTop: 12,
  },
  trustCard: {
    backgroundColor: '#FFFFFF',
    borderColor: '#E2E7EF',
    borderRadius: 18,
    borderWidth: 1,
    marginTop: 18,
    padding: 18,
  },
  trustTitle: {
    color: '#111827',
    fontSize: 15,
    fontWeight: '800',
    marginBottom: 12,
  },
  trustItem: {
    color: '#4B5563',
    fontSize: 13,
    lineHeight: 21,
    marginBottom: 5,
  },
  developmentNote: {
    color: '#9CA3AF',
    fontSize: 10,
    marginTop: 14,
    textAlign: 'center',
  },
  dataErrorCard: {
    backgroundColor: '#FEF2F2',
    borderColor: '#FECACA',
    borderRadius: 16,
    borderWidth: 1,
    marginTop: 26,
    padding: 18,
  },
  dataErrorTitle: {
    color: '#991B1B',
    fontSize: 15,
    fontWeight: '800',
  },
  dataErrorText: {
    color: '#B91C1C',
    fontSize: 13,
    lineHeight: 19,
    marginTop: 5,
  },
  continueButton: {
    alignItems: 'center',
    backgroundColor: '#1D4ED8',
    borderRadius: 16,
    justifyContent: 'center',
    marginTop: 28,
    minHeight: 58,
    paddingHorizontal: 20,
  },
  continueButtonDisabled: {
    backgroundColor: '#94A3B8',
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
});