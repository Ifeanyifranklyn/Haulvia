export const PRICING_RULE_VERSION = 'haulvia-pricing-v1.0.0';

export type ServiceType = 'expedited' | 'flex';

export type ScheduleDetailsPayload = {
  pickupLocation?: string;
  deliveryLocation?: string;
  description: string;
  category: string | null;
  quantity: number;
  weight: number | null;
  weightUnit: 'lb' | 'kg';
  dimensions: {
    length: number;
    width: number;
    height: number;
    unit: 'in' | 'cm';
  } | null;
  vehicleRequirement: string | null;
  specialInstructions: string | null;
  schedule: {
    pickupDate: string;
    pickupWindow:
      | 'morning'
      | 'afternoon'
      | 'evening'
      | 'flexible';
    deliveryPreference:
      | 'same-day'
      | 'next-day'
      | 'scheduled'
      | 'flexible';
    deliveryDate: string | null;
  };
};

export type PriceComponent = {
  code: string;
  label: string;
  amount: number;
};

export type PricingResult = {
  currency: 'CAD';
  ruleVersion: string;
  calculatedAt: string;

  assumptions: {
    estimatedDistanceKm: number;
    distanceSource: 'temporary-fallback';
  };

  expedited: {
    price: number;
    badge: 'FASTEST';
    pickupCommitment: string;
    deliveryCommitment: string;
    components: PriceComponent[];
  };

  flex: {
    suggestedMinimum: number;
    suggestedMaximum: number;
    recommendedBudget: number;
    badge: 'BEST VALUE';
    components: PriceComponent[];
  };
};

const VEHICLE_FEES: Record<string, number> = {
  car: 0,
  suv: 8,
  'pickup truck': 15,
  pickup: 15,
  'cargo van': 20,
  van: 20,
  'box truck': 38,
  'straight truck': 50,
};

function roundCurrency(value: number) {
  return Math.round(value * 100) / 100;
}

function normalizeVehicleRequirement(value: string | null) {
  return value?.trim().toLowerCase() ?? '';
}

function getVehicleFee(vehicleRequirement: string | null) {
  const normalizedVehicle =
    normalizeVehicleRequirement(vehicleRequirement);

  const matchingVehicle = Object.keys(VEHICLE_FEES).find((key) =>
    normalizedVehicle.includes(key),
  );

  return matchingVehicle
    ? VEHICLE_FEES[matchingVehicle]
    : 12;
}

function convertWeightToKilograms(
  weight: number | null,
  unit: 'lb' | 'kg',
) {
  if (!weight || weight <= 0) {
    return 0;
  }

  return unit === 'lb' ? weight * 0.453592 : weight;
}

export function calculatePrice(
  details: ScheduleDetailsPayload,
): PricingResult {
  /*
   * Temporary launch assumption.
   *
   * The current posting flow has pickup and delivery text, but it does not
   * yet provide verified route distance. This fallback will later be
   * replaced by a routing provider or backend distance calculation.
   */
  const estimatedDistanceKm = 20;

  const baseFee = 24;
  const distanceFee = estimatedDistanceKm * 1.15;

  const additionalQuantityFee =
    Math.max(0, details.quantity - 1) * 3;

  const weightKg = convertWeightToKilograms(
    details.weight,
    details.weightUnit,
  );

  const weightFee = Math.min(weightKg * 0.08, 35);
  const vehicleFee = getVehicleFee(
    details.vehicleRequirement,
  );

  const sameDayFee =
    details.schedule.deliveryPreference === 'same-day'
      ? 10
      : 0;

  const eveningFee =
    details.schedule.pickupWindow === 'evening' ? 6 : 0;

  const commonComponents: PriceComponent[] = [
    {
      code: 'base',
      label: 'Base service',
      amount: baseFee,
    },
    {
      code: 'distance',
      label: 'Estimated route',
      amount: distanceFee,
    },
    {
      code: 'quantity',
      label: 'Additional items',
      amount: additionalQuantityFee,
    },
    {
      code: 'weight',
      label: 'Load weight',
      amount: weightFee,
    },
    {
      code: 'vehicle',
      label: 'Vehicle requirement',
      amount: vehicleFee,
    },
    {
      code: 'same-day',
      label: 'Same-day delivery',
      amount: sameDayFee,
    },
    {
      code: 'evening',
      label: 'Evening pickup',
      amount: eveningFee,
    },
  ].filter((component) => component.amount > 0);

  const commonSubtotal = commonComponents.reduce(
    (total, component) => total + component.amount,
    0,
  );

  const expeditedPriorityFee = Math.max(
    14,
    commonSubtotal * 0.28,
  );

  const expeditedPrice = Math.max(
    49,
    commonSubtotal + expeditedPriorityFee,
  );

  const expeditedComponents: PriceComponent[] = [
    ...commonComponents,
    {
      code: 'expedited-priority',
      label: 'Expedited priority',
      amount: expeditedPriorityFee,
    },
  ];

  const flexRecommendedBudget = Math.max(
    35,
    commonSubtotal * 0.96,
  );

  const flexMinimum = flexRecommendedBudget * 0.9;
  const flexMaximum = flexRecommendedBudget * 1.12;

  return {
    currency: 'CAD',
    ruleVersion: PRICING_RULE_VERSION,
    calculatedAt: new Date().toISOString(),

    assumptions: {
      estimatedDistanceKm,
      distanceSource: 'temporary-fallback',
    },

    expedited: {
      price: roundCurrency(expeditedPrice),
      badge: 'FASTEST',
      pickupCommitment: 'Priority pickup target',
      deliveryCommitment: 'Direct priority delivery',
      components: expeditedComponents.map((component) => ({
        ...component,
        amount: roundCurrency(component.amount),
      })),
    },

    flex: {
      suggestedMinimum: roundCurrency(flexMinimum),
      suggestedMaximum: roundCurrency(flexMaximum),
      recommendedBudget: roundCurrency(
        flexRecommendedBudget,
      ),
      badge: 'BEST VALUE',
      components: commonComponents.map((component) => ({
        ...component,
        amount: roundCurrency(component.amount),
      })),
    },
  };
}